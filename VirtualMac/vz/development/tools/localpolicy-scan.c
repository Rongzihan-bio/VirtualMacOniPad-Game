#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

typedef struct __attribute__((packed)) {
    uint8_t type[16];
    uint8_t unique[16];
    uint64_t first_lba;
    uint64_t last_lba;
    uint64_t attributes;
    uint16_t name[36];
} gpt_entry;

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr, "usage: %s Disk.img LocalPolicy.bin\n", argv[0]);
        return 2;
    }
    int input = open(argv[1], O_RDONLY);
    if (input < 0) return perror(argv[1]), 1;
    uint8_t header[512];
    if (pread(input, header, sizeof(header), 512) != sizeof(header) ||
        memcmp(header, "EFI PART", 8))
        return fprintf(stderr, "invalid GPT\n"), 1;
    uint64_t entries_lba = *(uint64_t *)(header + 72);
    uint32_t entry_count = *(uint32_t *)(header + 80);
    uint32_t entry_size = *(uint32_t *)(header + 84);
    static const uint8_t isc_type[16] = {
        0x61,0x69,0x64,0x69,0x00,0x67,0xaa,0x11,
        0xaa,0x11,0x00,0x30,0x65,0x43,0xec,0xac,
    };
    uint64_t first = 0, last = 0;
    uint8_t entry_bytes[4096];
    if (!entry_count || entry_count > 1024 ||
        entry_size < sizeof(gpt_entry) || entry_size > sizeof(entry_bytes))
        return fprintf(stderr, "unsupported GPT\n"), 1;
    for (uint32_t index = 0; index < entry_count; ++index) {
        off_t offset = entries_lba * 512 + (uint64_t)index * entry_size;
        if (pread(input, entry_bytes, entry_size, offset) != entry_size)
            return perror("read GPT"), 1;
        gpt_entry *entry = (gpt_entry *)entry_bytes;
        if (!memcmp(entry->type, isc_type, sizeof(isc_type))) {
            first = entry->first_lba * 512;
            last = (entry->last_lba + 1) * 512;
            break;
        }
    }
    if (!first || last <= first)
        return fprintf(stderr, "iSC partition not found\n"), 1;
    uint8_t block[4096];
    for (uint64_t offset = first; offset + sizeof(block) <= last;
         offset += sizeof(block)) {
        if (pread(input, block, sizeof(block), offset) != sizeof(block))
            return perror("read iSC"), 1;
        if (block[0] != 0x30 || memcmp(block + 6, "IMG4", 4) ||
            !memmem(block, sizeof(block), "lpol", 4) ||
            !memmem(block, sizeof(block), "IM4M", 4))
            continue;
        static const uint8_t recovery_marker[] = {
            0x16, 0x04, 'r', 'o', 'l', 'p'
        };
        if (memmem(block, sizeof(block), recovery_marker,
                   sizeof(recovery_marker)))
            continue;
        int output = open(argv[2], O_WRONLY | O_CREAT | O_TRUNC, 0644);
        if (output < 0) return perror(argv[2]), 1;
        ssize_t written = write(output, block, sizeof(block));
        close(output);
        if (written != sizeof(block)) return perror("write policy"), 1;
        printf("0x%llx\n", (unsigned long long)offset);
        close(input);
        return 0;
    }
    close(input);
    return fprintf(stderr, "LocalPolicy not found\n"), 1;
}
