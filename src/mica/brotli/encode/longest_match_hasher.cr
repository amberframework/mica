module Mica::Brotli::Encode
  {% if flag?(:x86_64) %}
    # Bit i set when `tags[i]` (i < 16) equals the byte repeated in *splat*:
    # SSE2 PCMPEQB and PMOVMSKB over the sixteen bytes, passed in as two
    # words so the assembly reads no memory.
    @[AlwaysInline]
    def self.tag_mask16(tags : UInt8*, splat : UInt32) : UInt32
      low = Encode.load64(tags)
      high = Encode.load64(tags + 8)
      mask = 0_u32
      asm("movq $1, %xmm1\n\tmovq $2, %xmm2\n\tpunpcklqdq %xmm2, %xmm1\n\tmovd $3, %xmm0\n\tpshufd $$0, %xmm0, %xmm0\n\tpcmpeqb %xmm0, %xmm1\n\tpmovmskb %xmm1, $0"
              : "=r"(mask) : "r"(low), "r"(high), "r"(splat) : "xmm0", "xmm1", "xmm2")
      mask
    end
  {% end %}

  # google/brotli's H5 and H6 (qualities 7 to 9) and, with one tag byte
  # per slot, H58 and H68 (qualities 5 and 6): a table of 2^bucket_bits
  # buckets, each a ring of the latest 2^BLOCK_BITS positions whose first
  # *BYTES* bytes hash there. *BYTES* is 4 (H5, H58) or 5 (H6, H68, for
  # inputs of 1 MiB and more). Searches try the cached distances first,
  # then the bucket, then the static dictionary.
  #
  # :nodoc:
  class LongestMatchHasher(BYTES, TAGGED, BUCKET_BITS, BLOCK_BITS)
    TAG_BITS = 8

    getter dictionary = DictionarySearch.new
    @num_last_distances : Int32
    @num : Pointer(UInt16)
    @tags : Pointer(UInt8)
    @buckets : Pointer(UInt32)

    # The table shape is part of the type (one per quality and input
    # size), so the shifts and masks of the hot loops are constants.
    def initialize(@num_last_distances : Int32)
      @num = Encode.table(UInt16, 1 << BUCKET_BITS)
      @tags = TAGGED == 1 ? Encode.table(UInt8, 1 << (BUCKET_BITS + BLOCK_BITS)) : Pointer(UInt8).null
      @buckets = Encode.table(UInt32, 1 << (BUCKET_BITS + BLOCK_BITS))
    end

    # Slots per bucket.
    @[AlwaysInline]
    private def block_size : Int32
      1 << BLOCK_BITS
    end

    @[AlwaysInline]
    private def block_mask : UInt32
      (1_u32 << BLOCK_BITS) &- 1
    end

    # Right shift from the hashed word to the bucket (and tag) bits.
    @[AlwaysInline]
    private def hash_shift : Int32
      (BYTES == 4 ? 32 : 64) - BUCKET_BITS - (TAGGED == 1 ? TAG_BITS : 0)
    end

    # Bytes a search needs after its position.
    def hash_type_length : Int32
      BYTES == 4 ? 4 : 8
    end

    def store_lookahead : Int32
      hash_type_length
    end

    # Frees the tables (also done when the hasher is collected); the
    # hasher is unusable after.
    def release : Nil
      @num = Encode.free_table(@num)
      @tags = Encode.free_table(@tags)
      @buckets = Encode.free_table(@buckets)
    end

    def finalize
      release
    end

    # The hash: bucket in the high bits, tag in the low 8 when TAGGED.
    @[AlwaysInline]
    private def hash_bytes(data : UInt8*) : UInt32
      if BYTES == 4
        (Encode.load32(data) &* HASH_MUL32).unsafe_shr(hash_shift)
      else
        (Encode.load64(data) &* (HASH_MUL64 << 24)).unsafe_shr(hash_shift).to_u32!
      end
    end

    # Marks every bucket empty, or only the buckets of a short one-shot
    # input's positions.
    def prepare(one_shot : Bool, input_size : Int32, data : UInt8*, data_size : Int32) : Nil
      empty = TAGGED == 1 ? 65535_u16 : 0_u16
      if one_shot && input_size <= (1 << BUCKET_BITS) >> 6
        limit = Math.min(input_size, data_size &- hash_type_length &+ 1)
        limit.times do |position|
          key = hash_bytes(data + position)
          key >>= TAG_BITS if TAGGED == 1
          @num[key] = empty
        end
      else
        Slice.new(@num, 1 << BUCKET_BITS).fill(empty)
      end
    end

    @[AlwaysInline]
    def store(data : UInt8*, position : Int32) : Nil
      num = @num
      buckets = @buckets
      hash = hash_bytes(data + position)
      if TAGGED == 1
        key = hash >> TAG_BITS
        count = num[key]
        offset = (count.to_u32! & block_mask) &+ key.unsafe_shl(BLOCK_BITS)
        num[key] = count &- 1
        buckets[offset] = position.to_u32!
        @tags[offset] = hash.to_u8!
      else
        count = num[hash]
        offset = (count.to_u32! & block_mask) &+ hash.unsafe_shl(BLOCK_BITS)
        num[hash] = count &+ 1
        buckets[offset] = position.to_u32!
      end
    end

    def store_range(data : UInt8*, start : Int32, stop : Int32) : Nil
      num = @num
      buckets = @buckets
      tags = @tags
      position = start
      while position < stop
        hash = hash_bytes(data + position)
        if TAGGED == 1
          key = hash >> TAG_BITS
          count = num[key]
          offset = (count.to_u32! & block_mask) &+ key.unsafe_shl(BLOCK_BITS)
          num[key] = count &- 1
          buckets[offset] = position.to_u32!
          tags[offset] = hash.to_u8!
        else
          count = num[hash]
          offset = (count.to_u32! & block_mask) &+ hash.unsafe_shl(BLOCK_BITS)
          num[hash] = count &+ 1
          buckets[offset] = position.to_u32!
        end
        position &+= 1
      end
    end

    # Hashes the three positions before *position* once the bytes after
    # them have arrived.
    def stitch_to_previous_block(num_bytes : Int32, position : Int32, data : UInt8*) : Nil
      return unless num_bytes >= hash_type_length &- 1 && position >= 3
      store(data, position &- 3)
      store(data, position &- 2)
      store(data, position &- 1)
    end

    def prepare_distance_cache(cache : Int32*) : Nil
      Encode.prepare_distance_cache(cache, @num_last_distances)
    end

    # The best match at *position*, of at most *max_length* bytes and no
    # farther back than *max_backward*, into *result* (updated only when
    # better than its score); stores *position* in its bucket.
    @[AlwaysInline]
    def find_longest_match(data : UInt8*, cache : Int32*, position : Int32, max_length : Int32,
                           max_backward : Int32, dictionary_distance : Int32, max_distance : Int32,
                           result : SearchResult*) : Nil
      current = data + position
      # Locals, not fields: stores into the tables cannot then force reloads.
      num = @num
      min_score = result.value.score
      best_score = result.value.score
      best_length = result.value.length
      hash = hash_bytes(current)
      key = TAGGED == 1 ? hash >> TAG_BITS : hash
      bucket = @buckets + key.unsafe_shl(BLOCK_BITS)
      Encode.prefetch(bucket)
      if TAGGED == 1
        Encode.prefetch(@tags + key.unsafe_shl(BLOCK_BITS))
      end
      Encode.prefetch(bucket + 16) if BLOCK_BITS > 4
      found_length = 0
      found_distance = 0
      found_score = best_score
      found = false
      @num_last_distances.times do |slot|
        backward = cache[slot]
        next if backward <= 0 || backward > position
        next if backward > max_backward
        break if best_length >= max_length
        previous = current - backward
        next if previous[best_length] != current[best_length]
        length = Encode.match_length(previous, current, max_length)
        if length >= 3 || (length == 2 && slot < 2)
          score = Encode.score_using_last_distance(length)
          if best_score < score
            score &-= Encode.penalty_using_last_distance(slot) if slot != 0
            if best_score < score
              best_score = score
              best_length = length
              found_length = length
              found_distance = backward
              found_score = score
              found = true
            end
          end
        end
      end
      best_length = 3 if best_length < 3
      if TAGGED == 1
        tag = hash.to_u8!
        tag_bucket = @tags + key.unsafe_shl(BLOCK_BITS)
        head = (num[key].to_u32! &+ 1) & block_mask
        matches = matching_tag_mask(tag, tag_bucket, head)
        used = 65535_u32 &- num[key]
        if block_size.to_u32! > used
          matches &= 1_u64.unsafe_shl(used & 63) &- 1
        end
        while matches != 0
          slot = (head &+ matches.trailing_zeros_count.to_u32!) & block_mask
          matches &= matches &- 1
          previous_position = bucket[slot].to_i32!
          backward = position &- previous_position
          break if backward > max_backward || backward <= 0
          break if best_length >= max_length
          previous = data + previous_position
          next if Encode.load32(current + (best_length &- 3)) != Encode.load32(previous + (best_length &- 3))
          if BYTES == 4
            length = Encode.match_length(previous, current, max_length)
            next unless length >= 4
          else
            next if Encode.load32(current) != Encode.load32(previous)
            length = Encode.match_length(previous + 4, current + 4, max_length &- 4) &+ 4
          end
          score = Encode.backward_reference_score(length, backward)
          if best_score < score
            best_score = score
            best_length = length
            found_length = length
            found_distance = backward
            found_score = score
            found = true
          end
        end
        count = num[key]
        slot = count.to_u32! & block_mask
        bucket[slot] = position.to_u32!
        tag_bucket[slot] = tag
        num[key] = count &- 1
      else
        count = num[key].to_i32!
        down = count > block_size ? count &- block_size : 0
        index = count
        while index > down
          index &-= 1
          previous_position = bucket[index.to_u32! & block_mask].to_i32!
          backward = position &- previous_position
          break if backward > max_backward || backward <= 0
          break if best_length >= max_length
          previous = data + previous_position
          next if Encode.load32(current + (best_length &- 3)) != Encode.load32(previous + (best_length &- 3))
          if BYTES == 4
            length = Encode.match_length(previous, current, max_length)
            next unless length >= 4
          else
            next if Encode.load32(current) != Encode.load32(previous)
            length = Encode.match_length(previous + 4, current + 4, max_length &- 4) &+ 4
          end
          score = Encode.backward_reference_score(length, backward)
          if best_score < score
            best_score = score
            best_length = length
            found_length = length
            found_distance = backward
            found_score = score
            found = true
          end
        end
        bucket[num[key].to_u32! & block_mask] = position.to_u32!
        num[key] = num[key] &+ 1
      end
      if found
        result.value = SearchResult.new(found_length, 0, found_distance, found_score)
      else
        result.value.length = 0
        result.value.length_code_delta = 0
      end
      if min_score == result.value.score
        @dictionary.search(current, max_length, dictionary_distance, max_distance, result, false)
      end
    end

    # Bit i set when tag slot (head + i) of the bucket equals *tag*
    # (google/brotli's GetMatchingTagMask, the eight-byte version).
    @[AlwaysInline]
    private def matching_tag_mask(tag : UInt8, tag_bucket : UInt8*, head : UInt32) : UInt64
      {% if flag?(:x86_64) %}
        # SSE2 (every x86-64 CPU has it): one byte compare and mask per
        # sixteen tags, as google/brotli's GetMatchingTagMask does there.
        if block_size <= 32
          splat = tag.to_u32! &* 0x01010101_u32
          if block_size == 16
            value = Encode.tag_mask16(tag_bucket, splat).to_u16!
            shift = head & 15
            return (shift == 0 ? value : (value.unsafe_shr(shift) | value.unsafe_shl(16 &- shift))).to_u64!
          end
          value = Encode.tag_mask16(tag_bucket, splat) | Encode.tag_mask16(tag_bucket + 16, splat).unsafe_shl(16)
          shift = head & 31
          return (shift == 0 ? value : (value.unsafe_shr(shift) | value.unsafe_shl(32 &- shift))).to_u64!
        end
      {% end %}
      ones = 0x0101010101010101_u64
      highs = 0x8080808080808080_u64
      splat = tag.to_u64! &* ones
      extract = 0x0002040810204081_u64 # (2^64 - 1) / 0x7F >> 8: gathers the eight high bits
      chunk_count = block_size // 16
      matches = 0_u64
      index = chunk_count &* 16 &- 8
      while index >= 0
        chunk = Encode.load64(tag_bucket + index) ^ splat
        chunk = (((chunk | highs) &- ones) | chunk) & highs
        matches = (matches << 8) | ((chunk &* extract) >> 56)
        index &-= 8
      end
      matches = ~matches
      case chunk_count
      when 1
        value = matches.to_u16!
        shift = head & 15
        (shift == 0 ? value : (value.unsafe_shr(shift) | value.unsafe_shl(16 &- shift))).to_u64!
      when 2
        value = matches.to_u32!
        shift = head & 31
        (shift == 0 ? value : (value.unsafe_shr(shift) | value.unsafe_shl(32 &- shift))).to_u64!
      else
        shift = head & 63
        shift == 0 ? matches : (matches.unsafe_shr(shift) | matches.unsafe_shl(64 &- shift))
      end
    end
  end
end
