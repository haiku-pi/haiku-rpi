/*
 * bfsbits.c — a BFS volume's block bitmap as it is on the device against its superblock's used-blocks count:
 * tells the two kinds of checkfs's "blocks could be freed" apart (bits set that no file uses, or a stale
 * used_blocks count; checkfs computes it as used_blocks minus the blocks it found in use). `sync` first.
 *
 *   bfsbits DEVICE                 e.g. /dev/disk/virtual/remote_disk/0/1 (the partition, mounted or not)
 *   bfsbits DEVICE --save FILE     also writes the bitmap to FILE
 *   bfsbits DEVICE --freed FILE    also lists the blocks set in FILE's bitmap but clear now (run `checkfs DEVICE`
 *                                  between --save and --freed: the blocks it freed), and what each one holds
 *
 * Prints "bfsbits: DEVICE: block size B, N blocks, used_blocks U, bits set S (S - U = D)"; with --freed, a line
 * "bfsbits: freed BLOCK: inode, flags F, mode M, size Z, name 'N'" or "bfsbits: freed BLOCK: data" per block.
 *
 * Build (cross):
 *   g=sources/haiku/generated.arm64/cross-tools-arm64/bin/aarch64-unknown-haiku-gcc
 *   $g --sysroot=artifacts/sysroot-arm64 -O2 -o bfsbits tools/haiku-tests/bfsbits.c
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>


// what a freed block holds: an inode (a BFS inode's magic, its flags, mode, size and the first name-like string
// of its small data, at offset 232), or anything else
static void
describe(int fd, uint32_t blockSize, int64_t block)
{
	uint8_t data[4096];
	if (blockSize > sizeof(data) || pread(fd, data, blockSize, block * blockSize) != (ssize_t)blockSize) {
		printf("bfsbits: freed %lld: unreadable\n", (long long)block);
		return;
	}
	uint32_t magic, flags, mode;
	int64_t size;
	memcpy(&magic, data, 4);
	if (magic != 0x3bbe0ad9) {
		printf("bfsbits: freed %lld: data\n", (long long)block);
		return;
	}
	memcpy(&mode, data + 20, 4);
	memcpy(&flags, data + 24, 4);
	memcpy(&size, data + 208, 8);
	char name[64] = "";
	for (uint32_t i = 232, run = 0; i < blockSize; i++) {
		if (data[i] >= 0x21 && data[i] < 0x7f) {
			if (++run == 5) {
				uint32_t start = i - 4, n = 0;
				while (start + n < blockSize && data[start + n] >= 0x21 && data[start + n] < 0x7f
					&& n < sizeof(name) - 1)
					n++;
				memcpy(name, data + start, n);
				name[n] = '\0';
				break;
			}
		} else
			run = 0;
	}
	printf("bfsbits: freed %lld: inode, flags %#x, mode %#o, size %lld, name '%s'\n", (long long)block, flags,
		mode, (long long)size, name);
}


int
main(int argc, char** argv)
{
	if (argc != 2 && argc != 4) {
		fprintf(stderr, "usage: bfsbits DEVICE [--save FILE | --freed FILE]\n");
		return 2;
	}
	int fd = open(argv[1], O_RDONLY);
	if (fd < 0) {
		perror(argv[1]);
		return 1;
	}
	// disk_super_block (bfs.h) at offset 512: name[32], magic1, fs_byte_order, block_size, block_shift,
	// num_blocks, used_blocks (little endian on arm64)
	uint8_t sb[512];
	if (pread(fd, sb, sizeof(sb), 512) != (ssize_t)sizeof(sb)) {
		perror("superblock");
		return 1;
	}
	uint32_t magic1, blockSize;
	int64_t numBlocks, usedBlocks;
	memcpy(&magic1, sb + 32, 4);
	memcpy(&blockSize, sb + 40, 4);
	memcpy(&numBlocks, sb + 48, 8);
	memcpy(&usedBlocks, sb + 56, 8);
	if (magic1 != 0x42465331) {
		fprintf(stderr, "bfsbits: %s: no BFS superblock (magic %#x)\n", argv[1], magic1);
		return 1;
	}

	// the bitmap starts at block 1, one bit per block
	size_t bytes = (numBlocks + 7) / 8;
	uint8_t* bitmap = malloc(bytes);
	if (bitmap == NULL || pread(fd, bitmap, bytes, blockSize) != (ssize_t)bytes) {
		perror("bitmap");
		return 1;
	}
	int64_t bits = 0;
	for (int64_t i = 0; i < numBlocks; i++)
		bits += (bitmap[i / 8] >> (i % 8)) & 1;

	printf("bfsbits: %s: block size %u, %lld blocks, used_blocks %lld, bits set %lld (S - U = %lld)\n",
		argv[1], blockSize, (long long)numBlocks, (long long)usedBlocks, (long long)bits,
		(long long)(bits - usedBlocks));

	if (argc == 4 && strcmp(argv[2], "--save") == 0) {
		FILE* file = fopen(argv[3], "wb");
		if (file == NULL || fwrite(bitmap, 1, bytes, file) != bytes || fclose(file) != 0) {
			perror(argv[3]);
			return 1;
		}
	} else if (argc == 4 && strcmp(argv[2], "--freed") == 0) {
		uint8_t* saved = malloc(bytes);
		FILE* file = fopen(argv[3], "rb");
		if (saved == NULL || file == NULL || fread(saved, 1, bytes, file) != bytes) {
			perror(argv[3]);
			return 1;
		}
		fclose(file);
		int64_t freed = 0;
		for (int64_t i = 0; i < numBlocks; i++) {
			if (((saved[i / 8] >> (i % 8)) & 1) != 0 && ((bitmap[i / 8] >> (i % 8)) & 1) == 0) {
				describe(fd, blockSize, i);
				freed++;
			}
		}
		printf("bfsbits: %lld blocks freed since %s\n", (long long)freed, argv[3]);
	}
	return 0;
}
