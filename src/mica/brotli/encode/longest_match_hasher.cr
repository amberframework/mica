module Mica::Brotli::Encode
  # google/brotli's H5 and H6 (qualities 5 to 9, as libbrotlienc 1.1.0
  # uses them): a table of 2^BUCKET_BITS buckets, each a ring of the
  # latest 2^BLOCK_BITS positions whose first *BYTES* bytes hash there.
  # *BYTES* is 4 (H5) or 5 (H6, for inputs of 1 MiB and more). Searches
  # try the cached distances first, then the bucket, then the static
  # dictionary. google/brotli 1.2's tagged H58 and H68 (qualities 5 and
  # 6) find the same matches in the same order; on the measured x86-64
  # and aarch64 runners this untagged search was faster.
  #
  # :nodoc:
  class LongestMatchHasher(BYTES, BUCKET_BITS, BLOCK_BITS)
    getter dictionary = DictionarySearch.new
    @num_last_distances : Int32
    @num : Pointer(UInt16)
    @buckets : Pointer(UInt32)

    # The table shape is part of the type (one per quality and input
    # size), so the shifts and masks of the hot loops are constants.
    def initialize(@num_last_distances : Int32)
      @num = Encode.table(UInt16, 1 << BUCKET_BITS)
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

    # Right shift from the hashed word to the bucket bits.
    @[AlwaysInline]
    private def hash_shift : Int32
      (BYTES == 4 ? 32 : 64) - BUCKET_BITS
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
      @buckets = Encode.free_table(@buckets)
    end

    def finalize
      release
    end

    # The bucket of the first *BYTES* bytes at *data*.
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
      if one_shot && input_size <= (1 << BUCKET_BITS) >> 6
        limit = Math.min(input_size, data_size &- hash_type_length &+ 1)
        limit.times do |position|
          @num[hash_bytes(data + position)] = 0_u16
        end
      else
        Slice.new(@num, 1 << BUCKET_BITS).fill(0_u16)
      end
    end

    @[AlwaysInline]
    def store(data : UInt8*, position : Int32) : Nil
      num = @num
      buckets = @buckets
      hash = hash_bytes(data + position)
      count = num[hash]
      offset = (count.to_u32! & block_mask) &+ hash.unsafe_shl(BLOCK_BITS)
      num[hash] = count &+ 1
      buckets[offset] = position.to_u32!
    end

    def store_range(data : UInt8*, start : Int32, stop : Int32) : Nil
      num = @num
      buckets = @buckets
      position = start
      while position < stop
        hash = hash_bytes(data + position)
        count = num[hash]
        offset = (count.to_u32! & block_mask) &+ hash.unsafe_shl(BLOCK_BITS)
        num[hash] = count &+ 1
        buckets[offset] = position.to_u32!
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
      key = hash_bytes(current)
      bucket = @buckets + key.unsafe_shl(BLOCK_BITS)
      Encode.prefetch(bucket)
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
  end
end
