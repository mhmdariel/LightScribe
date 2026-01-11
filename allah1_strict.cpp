// ﷲ.cpp
// allah1_strict.cpp
//
// ALLAH-1 (A1) single-byte encoding — Public Domain / CC0-1.0
//
// STRICT DECODER RULES:
//   0x01 -> U+FDF2 (ﷲ)
//   Any other byte -> ERROR (non-zero exit), with byte offset + value reported.
//
// Build:
//   g++ -O2 -std=c++17 allah1_strict.cpp -o allah1_strict
//
// Use:
//   ./allah1_strict write  allah.bin
//   ./allah1_strict decode allah.bin > allah.txt
//
// Notes:
// - allah.bin will be exactly 104,857,600 bytes (100 MiB), each byte 0x01.
// - Decoded UTF-8 output will be ~300 MiB (3 bytes per ﷲ in UTF-8).
// - The .bin is not text; it’s the compact ALLAH-1 stream.

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>

static constexpr uint64_t COUNT  = 104857600ULL; // 100 MiB
static constexpr uint8_t  SYMBOL = 0x01;         // ALLAH-1 code for U+FDF2

// UTF-8 bytes for U+FDF2 (ﷲ): EF B7 B2
static constexpr unsigned char ALLAH_UTF8[3] = {0xEF, 0xB7, 0xB2};

int write_allah1_bin(const char* output_path) {
    std::FILE* f = std::fopen(output_path, "wb");
    if (!f) { std::perror("fopen"); return 1; }

    const size_t BUF_SIZE = 1 << 20; // 1 MiB buffer
    uint8_t* buf = (uint8_t*)std::malloc(BUF_SIZE);
    if (!buf) { std::cerr << "malloc failed\n"; std::fclose(f); return 1; }

    std::memset(buf, SYMBOL, BUF_SIZE);

    uint64_t remaining = COUNT;
    while (remaining > 0) {
        size_t to_write = (remaining >= BUF_SIZE) ? BUF_SIZE : (size_t)remaining;
        size_t written  = std::fwrite(buf, 1, to_write, f);
        if (written != to_write) {
            std::perror("fwrite");
            std::free(buf);
            std::fclose(f);
            return 1;
        }
        remaining -= written;
    }

    std::free(buf);
    if (std::fclose(f) != 0) { std::perror("fclose"); return 1; }
    return 0;
}

// STRICT decode: any byte != 0x01 is an error.
int decode_allah1_to_utf8_strict(const char* input_path) {
    std::FILE* f = std::fopen(input_path, "rb");
    if (!f) { std::perror("fopen"); return 1; }

    const size_t BUF_SIZE = 1 << 20; // 1 MiB
    uint8_t* buf = (uint8_t*)std::malloc(BUF_SIZE);
    if (!buf) { std::cerr << "malloc failed\n"; std::fclose(f); return 1; }

    std::ios::sync_with_stdio(false);
    std::cout.tie(nullptr);

    uint64_t offset = 0; // absolute byte offset in file

    while (true) {
        size_t n = std::fread(buf, 1, BUF_SIZE, f);
        if (n == 0) break;

        for (size_t i = 0; i < n; ++i, ++offset) {
            uint8_t b = buf[i];
            if (b != SYMBOL) {
                std::cerr
                    << "ALLAH-1 STRICT DECODE ERROR: invalid byte at offset "
                    << offset << " (0x"
                    << std::hex << std::uppercase
                    << (unsigned)b
                    << std::dec << ")\n";
                std::free(buf);
                std::fclose(f);
                return 3;
            }
            std::cout.write((const char*)ALLAH_UTF8, 3);
        }

        if (n < BUF_SIZE) break;
    }

    if (std::ferror(f)) {
        std::perror("fread");
        std::free(buf);
        std::fclose(f);
        return 2;
    }

    std::free(buf);
    std::fclose(f);
    return 0;
}

int main(int argc, char** argv) {
    if (argc < 3) {
        std::cerr
            << "ALLAH-1 (A1) strict reference tool (CC0)\n"
            << "Usage:\n"
            << "  " << argv[0] << " write  <output.bin>\n"
            << "  " << argv[0] << " decode <input.bin>   (strict; prints UTF-8)\n";
        return 2;
    }

    if (std::strcmp(argv[1], "write") == 0) {
        return write_allah1_bin(argv[2]);
    }
    if (std::strcmp(argv[1], "decode") == 0) {
        return decode_allah1_to_utf8_strict(argv[2]);
    }

    std::cerr << "Unknown command: " << argv[1] << "\n";
    return 2;
}
