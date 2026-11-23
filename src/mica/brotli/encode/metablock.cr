module Mica::Brotli::Encode
  # *count* histograms of *data_size* symbols each, in one flat buffer,
  # with each histogram's total.
  class HistogramSet
    getter data_size : Int32
    getter count : Int32
    @data : Pointer(UInt32)
    getter totals : Slice(UInt64)
    getter bit_costs : Slice(Float64)

    # With *cleared* false the counts start undefined: for sets whose
    # histograms are each cleared or overwritten before use.
    # Storage comes from *arena* when given (dropped with it), else from
    # the collector. With *cleared* false the counts start undefined: for
    # sets whose histograms are each cleared or overwritten before use.
    def initialize(@data_size : Int32, @count : Int32, arena : Arena? = nil, cleared : Bool = true)
      cells = Math.max(@data_size &* @count, 1)
      slots = Math.max(@count, 1)
      if arena
        @data = arena.alloc(UInt32, cells)
        @totals = Slice.new(arena.alloc_cleared(UInt64, slots), @count)
        @bit_costs = Slice.new(arena.alloc_cleared(Float64, slots), @count)
      else
        @data = GC.malloc_atomic(LibC::SizeT.new(cells) * sizeof(UInt32)).as(UInt32*)
        @totals = Slice(UInt64).new(@count, 0_u64)
        @bit_costs = Slice(Float64).new(@count, 0.0)
      end
      @data.clear(cells) if cleared
    end

    @[AlwaysInline]
    def [](index : Int) : Pointer(UInt32)
      @data + index &* @data_size
    end

    @[AlwaysInline]
    def add(index : Int, symbol : Int) : Nil
      self[index][symbol] &+= 1
      @totals.to_unsafe[index] &+= 1
    end

    def clear(index : Int) : Nil
      self[index].clear(@data_size)
      @totals[index] = 0_u64
    end

    # Copies histogram *from* of *source* into histogram *to*.
    def copy(to : Int, source : HistogramSet, from : Int) : Nil
      self[to].copy_from(source[from], @data_size)
      @totals[to] = source.totals[from]
      @bit_costs[to] = source.bit_costs[from]
    end

    # Adds histogram *from* of *source* into histogram *to*.
    def add_histogram(to : Int, source : HistogramSet, from : Int) : Nil
      target = self[to]
      other = source[from]
      @data_size.times { |symbol| target[symbol] &+= other[symbol] }
      @totals[to] &+= source.totals[from]
    end

    # Keeps only the first *count* histograms.
    def truncate(count : Int32) : Nil
      @count = count
    end
  end

  # The block types and lengths of one category of a metablock.
  class BlockSplit
    getter types : Bytes
    getter lengths : Slice(UInt32)
    property num_types = 0
    property num_blocks = 0

    def initialize(capacity : Int32 = 1, arena : Arena? = nil)
      size = Math.max(capacity, 1)
      if arena
        @types = Slice.new(arena.alloc_cleared(UInt8, size), size)
        @lengths = Slice.new(arena.alloc_cleared(UInt32, size), size)
      else
        @types = Bytes.new(size)
        @lengths = Slice(UInt32).new(size, 0_u32)
      end
    end
  end

  # How a metablock is modeled: the block splits, the context maps (empty
  # when trivial) and the histograms the prefix codes come from.
  class MetaBlock
    property literal_split : BlockSplit
    property command_split : BlockSplit
    property distance_split : BlockSplit
    property literal_context_map = Slice(UInt32).empty
    property distance_context_map = Slice(UInt32).empty
    property literal_histograms : HistogramSet
    property command_histograms : HistogramSet
    property distance_histograms : HistogramSet

    def initialize(@literal_split, @command_split, @distance_split, @literal_histograms, @command_histograms,
                   @distance_histograms)
    end
  end

  # The greedy block splitter of qualities 4 to 9 for one category
  # (google/brotli's BlockSplitter and ContextBlockSplitter): each block
  # of at least *min_block_size* symbols becomes a new type when that
  # saves more than *split_threshold* bits against both of the last two
  # types, joins the second last type when that is clearly cheaper, and
  # otherwise extends the last block. Literal blocks keep one histogram
  # per static context.
  class GreedyBlockSplitter
    getter histograms : HistogramSet

    @max_block_types : Int32
    @target_block_size : Int32
    @block_size = 0
    @current = 0
    @last = StaticArray(Int32, 2).new(0)
    @last_entropy : Slice(Float64)
    @merge_last_count = 0
    @num_blocks = 0
    @combined : HistogramSet
    @entropy : Slice(Float64)
    @combined_entropy : Slice(Float64)

    def initialize(arena : Arena, @alphabet_size : Int32, data_size : Int32, @num_contexts : Int32,
                   @min_block_size : Int32, @split_threshold : Float64, num_symbols : Int64)
      max_num_blocks = (num_symbols // @min_block_size &+ 1).to_i32!
      @max_block_types = MAX_BLOCK_TYPES // @num_contexts
      max_num_types = Math.min(max_num_blocks, @max_block_types &+ 1)
      @split = BlockSplit.new(max_num_blocks, arena)
      @split.num_blocks = max_num_blocks
      @target_block_size = @min_block_size
      @histograms = HistogramSet.new(data_size, max_num_types &* @num_contexts, arena, cleared: false)
      @last_entropy = Slice.new(arena.alloc_cleared(Float64, 2 &* @num_contexts), 2 &* @num_contexts)
      @combined = HistogramSet.new(data_size, 2 &* @num_contexts, arena, cleared: false)
      @entropy = Slice.new(arena.alloc_cleared(Float64, @num_contexts), @num_contexts)
      @combined_entropy = Slice.new(arena.alloc_cleared(Float64, 2 &* @num_contexts), 2 &* @num_contexts)
      clear_current
    end

    getter split : BlockSplit

    @[AlwaysInline]
    def add(symbol : Int, context : Int = 0) : Nil
      @histograms.add(@current &+ context, symbol)
      @block_size &+= 1
      finish_block(false) if @block_size == @target_block_size
    end

    def finish_block(is_final : Bool) : Nil
      split = @split
      contexts = @num_contexts
      @block_size = @min_block_size if @block_size < @min_block_size
      if @num_blocks == 0
        split.lengths[0] = @block_size.to_u32!
        split.types[0] = 0_u8
        contexts.times do |i|
          @last_entropy[i] = Encode.bits_entropy(@histograms[i], @alphabet_size)
          @last_entropy[contexts &+ i] = @last_entropy[i]
        end
        @num_blocks &+= 1
        split.num_types &+= 1
        @current &+= contexts
        clear_current if @current < @histograms.count
        @block_size = 0
      elsif @block_size > 0
        diff = StaticArray(Float64, 2).new(0.0)
        contexts.times do |i|
          current = @current &+ i
          @entropy[i] = Encode.bits_entropy(@histograms[current], @alphabet_size)
          2.times do |j|
            jx = j &* contexts &+ i
            @combined.copy(jx, @histograms, current)
            @combined.add_histogram(jx, @histograms, @last[j] &+ i)
            @combined_entropy[jx] = Encode.bits_entropy(@combined[jx], @alphabet_size)
            diff[j] += @combined_entropy[jx] - @entropy[i] - @last_entropy[jx]
          end
        end
        if split.num_types < @max_block_types && diff[0] > @split_threshold && diff[1] > @split_threshold
          split.lengths[@num_blocks] = @block_size.to_u32!
          split.types[@num_blocks] = split.num_types.to_u8!
          @last[1] = @last[0]
          @last[0] = split.num_types &* contexts
          contexts.times do |i|
            @last_entropy[contexts &+ i] = @last_entropy[i]
            @last_entropy[i] = @entropy[i]
          end
          @num_blocks &+= 1
          split.num_types &+= 1
          @current &+= contexts
          clear_current if @current < @histograms.count
          @block_size = 0
          @merge_last_count = 0
          @target_block_size = @min_block_size
        elsif diff[1] < diff[0] - 20.0
          split.lengths[@num_blocks] = @block_size.to_u32!
          split.types[@num_blocks] = split.types[@num_blocks &- 2]
          @last[0], @last[1] = @last[1], @last[0]
          contexts.times do |i|
            @histograms.copy(@last[0] &+ i, @combined, contexts &+ i)
            @last_entropy[contexts &+ i] = @last_entropy[i]
            @last_entropy[i] = @combined_entropy[contexts &+ i]
            @histograms.clear(@current &+ i)
          end
          @num_blocks &+= 1
          @block_size = 0
          @merge_last_count = 0
          @target_block_size = @min_block_size
        else
          split.lengths[@num_blocks &- 1] &+= @block_size.to_u32!
          contexts.times do |i|
            @histograms.copy(@last[0] &+ i, @combined, i)
            @last_entropy[i] = @combined_entropy[i]
            @last_entropy[contexts &+ i] = @last_entropy[i] if split.num_types == 1
            @histograms.clear(@current &+ i)
          end
          @block_size = 0
          @merge_last_count &+= 1
          @target_block_size &+= @min_block_size if @merge_last_count > 1
        end
      end
      if is_final
        @histograms.truncate(split.num_types &* contexts)
        split.num_blocks = @num_blocks
      end
    end

    private def clear_current : Nil
      @num_contexts.times { |i| @histograms.clear(@current &+ i) }
    end
  end

  module MetablockBuilder
    # google/brotli's static literal context maps (encode.c).
    CONTEXT_MAP_CONTINUATION = StaticArray[
      1_u32, 1_u32, 2_u32, 2_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32,
      0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32,
      0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32,
      0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32,
    ]
    CONTEXT_MAP_SIMPLE_UTF8 = StaticArray[
      0_u32, 0_u32, 1_u32, 1_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32,
      0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32,
      0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32,
      0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32, 0_u32,
    ]
    CONTEXT_MAP_COMPLEX_UTF8 = StaticArray[
      11_u32, 11_u32, 12_u32, 12_u32, 0_u32, 0_u32, 0_u32, 0_u32, 1_u32, 1_u32, 9_u32, 9_u32, 2_u32, 2_u32, 2_u32, 2_u32,
      1_u32, 1_u32, 1_u32, 1_u32, 8_u32, 3_u32, 3_u32, 3_u32, 1_u32, 1_u32, 1_u32, 1_u32, 2_u32, 2_u32, 2_u32, 2_u32,
      8_u32, 4_u32, 4_u32, 4_u32, 8_u32, 7_u32, 4_u32, 4_u32, 8_u32, 0_u32, 0_u32, 0_u32, 3_u32, 3_u32, 3_u32, 3_u32,
      5_u32, 5_u32, 10_u32, 5_u32, 5_u32, 5_u32, 10_u32, 5_u32, 6_u32, 6_u32, 6_u32, 6_u32, 6_u32, 6_u32, 6_u32, 6_u32,
    ]
    MAX_STATIC_CONTEXTS = 13

    # Chooses 1, 2, 3 or 13 literal contexts from bigram statistics of the
    # UTF-8 byte classes, sampled 64 bytes in every 4 KiB (google/brotli's
    # DecideOverLiteralContextModeling). Returns the count and the map
    # from the 64 UTF8-mode contexts to them.
    def self.decide_over_literal_context_modeling(data : UInt8*, start : Int32, length : Int32, quality : Int32,
                                                  size_hint : Int64) : {Int32, Pointer(UInt32)}
      none = {1, Pointer(UInt32).null}
      return none if quality < 5 || length < 64
      if complex = complex_static_context_map(data, start, length, size_hint)
        return complex
      end
      stop = start &+ length
      bigram = StaticArray(UInt32, 9).new(0_u32)
      lut = StaticArray[0, 0, 1, 2]
      position = start
      while position &+ 64 <= stop
        previous = lut[data[position] >> 6] &* 3
        (position &+ 1...position &+ 64).each do |at|
          literal = data[at]
          bigram[previous &+ lut[literal >> 6]] &+= 1
          previous = lut[literal >> 6] &* 3
        end
        position &+= 4096
      end
      choose_context_map(quality, bigram)
    end

    private def self.choose_context_map(quality : Int32, bigram : StaticArray(UInt32, 9)) : {Int32, Pointer(UInt32)}
      monogram = StaticArray(UInt32, 3).new(0_u32)
      two_prefix = StaticArray(UInt32, 6).new(0_u32)
      9.times do |i|
        monogram[i % 3] &+= bigram[i]
        two_prefix[i % 6] &+= bigram[i]
      end
      entropy = StaticArray(Float64, 4).new(0.0)
      entropy[1] = Encode.estimate_entropy(monogram.to_unsafe, 3)
      entropy[2] = Encode.estimate_entropy(two_prefix.to_unsafe, 3) + Encode.estimate_entropy(two_prefix.to_unsafe + 3, 3)
      3.times { |i| entropy[3] += Encode.estimate_entropy(bigram.to_unsafe + 3 &* i, 3) }
      total = monogram[0] &+ monogram[1] &+ monogram[2]
      entropy[0] = 1.0 / total
      entropy[1] *= entropy[0]
      entropy[2] *= entropy[0]
      entropy[3] *= entropy[0]
      entropy[3] = entropy[1] * 10 if quality < 7
      if entropy[1] - entropy[2] < 0.2 && entropy[1] - entropy[3] < 0.2
        {1, Pointer(UInt32).null}
      elsif entropy[2] - entropy[3] < 0.02
        {2, CONTEXT_MAP_SIMPLE_UTF8.to_unsafe}
      else
        {3, CONTEXT_MAP_CONTINUATION.to_unsafe}
      end
    end

    private def self.complex_static_context_map(data : UInt8*, start : Int32, length : Int32,
                                                size_hint : Int64) : {Int32, Pointer(UInt32)}?
      return nil if size_hint < (1 << 20)
      stop = start &+ length
      combined = StaticArray(UInt32, 32).new(0_u32)
      context_histogram = StaticArray(UInt32, 416).new(0_u32)
      total = 0_u32
      lut = Tables::CONTEXT_LOOKUP.to_unsafe + CONTEXT_UTF8 &* 512
      position = start
      while position &+ 64 <= stop
        previous2 = data[position]
        previous1 = data[position &+ 1]
        (position &+ 2...position &+ 64).each do |at|
          literal = data[at]
          context = CONTEXT_MAP_COMPLEX_UTF8[lut[previous1] | lut[256 &+ previous2]]
          total &+= 1
          combined[literal >> 3] &+= 1
          context_histogram[(context << 5) &+ (literal >> 3)] &+= 1
          previous2 = previous1
          previous1 = literal
        end
        position &+= 4096
      end
      entropy1 = Encode.estimate_entropy(combined.to_unsafe, 32)
      entropy2 = 0.0
      MAX_STATIC_CONTEXTS.times { |i| entropy2 += Encode.estimate_entropy(context_histogram.to_unsafe + (i << 5), 32) }
      scale = 1.0 / total
      entropy1 *= scale
      entropy2 *= scale
      return nil if entropy2 > 3.0 || entropy1 - entropy2 < 0.2
      {MAX_STATIC_CONTEXTS, CONTEXT_MAP_COMPLEX_UTF8.to_unsafe}
    end

    # The greedy metablock of qualities 4 to 9 (google/brotli's
    # BrotliBuildMetaBlockGreedy).
    def self.build_greedy(data : UInt8*, position : Int32, previous_byte : UInt8, previous_byte2 : UInt8,
                          num_contexts : Int32, static_context_map : Pointer(UInt32),
                          commands : CommandBuffer, arena : Arena) : MetaBlock
      lut = Tables::CONTEXT_LOOKUP.to_unsafe + CONTEXT_UTF8 &* 512
      num_literals = 0_i64
      commands.size.times { |i| num_literals &+= commands[i].insert_length }
      literal = GreedyBlockSplitter.new(arena, 256, NUM_LITERAL_SYMBOLS, num_contexts, 512, 400.0, num_literals)
      command = GreedyBlockSplitter.new(arena, NUM_COMMAND_SYMBOLS, NUM_COMMAND_SYMBOLS, 1, 1024, 500.0, commands.size.to_i64!)
      distance = GreedyBlockSplitter.new(arena, 64, NUM_HISTOGRAM_DISTANCES, 1, 512, 100.0, commands.size.to_i64!)
      commands.size.times do |i|
        entry = commands[i]
        command.add(entry.command_prefix)
        if num_contexts == 1
          entry.insert_length.times do
            literal.add(data[position])
            position &+= 1
          end
        else
          entry.insert_length.times do
            byte = data[position]
            literal.add(byte, static_context_map[lut[previous_byte] | lut[256 &+ previous_byte2]])
            previous_byte2 = previous_byte
            previous_byte = byte
            position &+= 1
          end
        end
        copy = entry.copy_length.to_i32!
        position &+= copy
        if copy != 0
          previous_byte2 = data[position &- 2]
          previous_byte = data[position &- 1]
          distance.add(entry.distance_prefix & 0x3FF) if entry.command_prefix >= 128
        end
      end
      literal.finish_block(true)
      command.finish_block(true)
      distance.finish_block(true)
      metablock = MetaBlock.new(literal.split, command.split, distance.split, literal.histograms, command.histograms,
        distance.histograms)
      if num_contexts > 1
        types = metablock.literal_split.num_types
        map = Slice.new(arena.alloc(UInt32, types << LITERAL_CONTEXT_BITS), types << LITERAL_CONTEXT_BITS)
        types.times do |type|
          offset = (type &* num_contexts).to_u32!
          64.times { |context| map[(type << LITERAL_CONTEXT_BITS) &+ context] = offset &+ static_context_map[context] }
        end
        metablock.literal_context_map = map
      end
      metablock
    end

    # google/brotli's BrotliOptimizeHistograms.
    def self.optimize_histograms(num_distance_codes : Int32, metablock : MetaBlock, arena : Arena) : Nil
      good_for_rle = Slice.new(arena.alloc(UInt8, NUM_COMMAND_SYMBOLS), NUM_COMMAND_SYMBOLS)
      {% for category in %w(literal command distance) %}
        histograms = metablock.{{category.id}}_histograms
        length = {{ category == "literal" ? "NUM_LITERAL_SYMBOLS".id : (category == "command" ? "NUM_COMMAND_SYMBOLS".id : "num_distance_codes".id) }}
        histograms.count.times do |i|
          Entropy.optimize_for_rle(length, histograms[i], good_for_rle.to_unsafe)
        end
      {% end %}
    end
  end
end
