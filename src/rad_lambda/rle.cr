module RadLambda
  # Byte RLE, copied verbatim in behavior from the rle shard (crmorello/rle)
  # so RAD output stays byte-identical: (uint8 value, uint16 LE count) pairs,
  # runs capped at UInt16::MAX.
  module RLE
    def self.compress(data : Bytes) : Bytes
      buffer = IO::Memory.new(data.size)
      i = 0
      while i < data.size
        value = data[i]
        count = count_repeating(data, i)

        buffer.write_byte(value)
        buffer.write_bytes(count.to_u16, IO::ByteFormat::LittleEndian)
        i += count
      end
      buffer.to_slice
    end

    def self.decompress(compressed : Bytes, original_size : Int64) : Bytes
      buffer = IO::Memory.new(original_size)
      i = 0
      while i < compressed.size
        value = compressed[i]
        i += 1
        count = IO::ByteFormat::LittleEndian.decode(UInt16, compressed[i, 2])
        i += 2
        buffer.write(Bytes.new(count.to_i32, value))
      end
      buffer.to_slice
    end

    # ---- v2: skip-literal ("RAD2" streams) ----------------------------------
    # Measured on live data, v1 spends 93% of its bytes on ~2-texel precip
    # runs (textured weather doesn't repeat): 1.44 bytes/texel where raw
    # literals cost 1.0. v2 tokens: [varint zero_skip][varint literal_len]
    # [literal bytes]; zero gaps shorter than GAP_MERGE are cheaper kept as
    # literal zeros than as a new token. -38% size, 6-7x faster decode.
    GAP_MERGE = 4

    def self.compress_v2(data : Bytes) : Bytes
      buffer = IO::Memory.new(data.size // 8)
      i = 0
      while i < data.size
        skip = 0
        while i < data.size && data[i] == 0
          skip += 1
          i += 1
        end
        start = i
        j = i
        while j < data.size
          if data[j] != 0
            j += 1
            next
          end
          z = 0
          k = j
          while k < data.size && data[k] == 0 && z < GAP_MERGE
            z += 1
            k += 1
          end
          break if z >= GAP_MERGE || k >= data.size
          j = k
        end
        write_varint(buffer, skip)
        write_varint(buffer, j - start)
        buffer.write(data[start, j - start])
        i = j
      end
      buffer.to_slice
    end

    def self.decompress_v2(compressed : Bytes, original_size : Int64) : Bytes
      out = Bytes.new(original_size.to_i32)
      i = 0
      pos = 0
      while i < compressed.size
        skip, i = read_varint(compressed, i)
        lit, i = read_varint(compressed, i)
        pos += skip
        out[pos, lit].copy_from(compressed[i, lit])
        i += lit
        pos += lit
      end
      out
    end

    private def self.write_varint(io : IO, value : Int32)
      v = value
      while v >= 128
        io.write_byte(((v & 127) | 128).to_u8)
        v >>= 7
      end
      io.write_byte(v.to_u8)
    end

    private def self.read_varint(data : Bytes, i : Int32) : {Int32, Int32}
      value = 0
      shift = 0
      loop do
        byte = data[i]
        i += 1
        value |= (byte & 127).to_i32 << shift
        break if byte & 128 == 0
        shift += 7
      end
      {value, i}
    end

    private def self.count_repeating(data : Bytes, start : Int32) : Int32
      count = 0
      value = data[start]
      while start < data.size && data[start] == value && count < UInt16::MAX
        count += 1
        start += 1
      end
      count
    end
  end
end
