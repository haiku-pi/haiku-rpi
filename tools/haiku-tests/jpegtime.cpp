/*
 * jpegtime — the CPU's JPEG decoding, the baseline for the VideoCore's (mmal-codec jpegdec;
 * docs/design/videocore-services.md):
 *
 *   jpegtime [-n N] FILE.jpg
 *   jpegtime [-n N] -e WxH FILE.yuv     (encode an I420 picture, quality 85: the VideoCore jpegenc counterpart)
 *
 * N times each (default 5): libjpeg-turbo (the system's libjpeg) to BGRX, i.e. B_RGB32, as one call per
 * picture (the decoding alone, the file in memory); libjpeg-turbo to its raw planar YCbCr (no colour
 * conversion: what the VideoCore's I420 output corresponds to); and BTranslationUtils::GetBitmapFile() on
 * the file (Haiku's JPEG translator, what ShowImage and other applications get). Lines "JPEG ...".
 *
 * Copyright 2026, Haiku-Pi project. Distributed under the terms of the MIT License.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <Application.h>
#include <Bitmap.h>
#include <OS.h>
#include <TranslationUtils.h>

extern "C" {
#include <jpeglib.h>
}


static void
decode(const unsigned char* data, size_t size, bool raw, unsigned char* out, size_t* outSize,
	unsigned* width, unsigned* height)
{
	jpeg_decompress_struct info;
	jpeg_error_mgr error;
	info.err = jpeg_std_error(&error);
	jpeg_create_decompress(&info);
	jpeg_mem_src(&info, data, size);
	jpeg_read_header(&info, TRUE);
	*width = info.image_width;
	*height = info.image_height;
	if (raw) {
		// planar YCbCr at the file's own sampling, in iMCU-row blocks
		info.raw_data_out = TRUE;
		jpeg_start_decompress(&info);
		int rows = info.max_v_samp_factor * DCTSIZE;
		JSAMPROW rowPointers[3][4 * DCTSIZE];
		JSAMPARRAY planes[3] = { rowPointers[0], rowPointers[1], rowPointers[2] };
		size_t offset = 0;
		while (info.output_scanline < info.output_height) {
			for (int c = 0; c < 3; c++) {
				jpeg_component_info* comp = &info.comp_info[c];
				int compRows = comp->v_samp_factor * DCTSIZE;
				size_t pitch = comp->width_in_blocks * DCTSIZE;
				for (int r = 0; r < compRows; r++) {
					rowPointers[c][r] = out + offset;
					offset += pitch;
				}
			}
			jpeg_read_raw_data(&info, planes, rows);
		}
		*outSize = offset;
	} else {
		info.out_color_space = JCS_EXT_BGRX;
		jpeg_start_decompress(&info);
		size_t pitch = (size_t)info.output_width * 4;
		while (info.output_scanline < info.output_height) {
			JSAMPROW row = out + (size_t)info.output_scanline * pitch;
			jpeg_read_scanlines(&info, &row, 1);
		}
		*outSize = pitch * info.output_height;
	}
	jpeg_finish_decompress(&info);
	jpeg_destroy_decompress(&info);
}


/* -e WxH FILE.yuv: libjpeg-turbo encodes the I420 picture (raw YCbCr in, 4:2:0, quality 85), the VideoCore's
   jpegenc counterpart */
static int
encode_raw(const char* size, const char* path, int count)
{
	unsigned width, height;
	if (sscanf(size, "%ux%u", &width, &height) != 2)
		return 2;
	FILE* file = fopen(path, "rb");
	if (file == NULL)
		return 1;
	size_t frame = (size_t)width * height * 3 / 2;
	unsigned char* yuv = (unsigned char*)malloc(frame);
	if (fread(yuv, 1, frame, file) != frame)
		return 1;
	fclose(file);
	unsigned long outSize = 0;
	bigtime_t start = system_time();
	for (int i = 0; i < count; i++) {
		jpeg_compress_struct info;
		jpeg_error_mgr error;
		unsigned char* out = NULL;
		outSize = 0;
		info.err = jpeg_std_error(&error);
		jpeg_create_compress(&info);
		jpeg_mem_dest(&info, &out, &outSize);
		info.image_width = width;
		info.image_height = height;
		info.input_components = 3;
		info.in_color_space = JCS_YCbCr;
		jpeg_set_defaults(&info);
		jpeg_set_quality(&info, 85, TRUE);
		info.raw_data_in = TRUE;
		info.comp_info[0].h_samp_factor = info.comp_info[0].v_samp_factor = 2;
		info.comp_info[1].h_samp_factor = info.comp_info[1].v_samp_factor = 1;
		info.comp_info[2].h_samp_factor = info.comp_info[2].v_samp_factor = 1;
		jpeg_start_compress(&info, TRUE);
		JSAMPROW rows[3][2 * DCTSIZE];
		JSAMPARRAY planes[3] = { rows[0], rows[1], rows[2] };
		while (info.next_scanline < info.image_height) {
			for (int r = 0; r < 2 * DCTSIZE; r++) {
				unsigned y = info.next_scanline + r < height ? info.next_scanline + r : height - 1;
				rows[0][r] = yuv + (size_t)y * width;
			}
			for (int r = 0; r < DCTSIZE; r++) {
				unsigned y = info.next_scanline / 2 + r < height / 2 ? info.next_scanline / 2 + r : height / 2 - 1;
				rows[1][r] = yuv + (size_t)width * height + (size_t)y * (width / 2);
				rows[2][r] = yuv + (size_t)width * height * 5 / 4 + (size_t)y * (width / 2);
			}
			jpeg_write_raw_data(&info, planes, 2 * DCTSIZE);
		}
		jpeg_finish_compress(&info);
		jpeg_destroy_compress(&info);
		free(out);
	}
	bigtime_t wall = system_time() - start;
	printf("JPEG libjpeg-turbo encode %ux%u (raw 4:2:0, quality 85): %d in %.3f s, %.2f ms each, %lu bytes\n",
		width, height, count, wall / 1e6, wall / 1e3 / count, outSize);
	return 0;
}


int
main(int argc, char** argv)
{
	int count = 5, opt;
	const char* encodeSize = NULL;
	while ((opt = getopt(argc, argv, "n:e:")) != -1) {
		if (opt == 'n')
			count = atoi(optarg);
		else if (opt == 'e')
			encodeSize = optarg;
		else
			return 2;
	}
	if (encodeSize != NULL && optind == argc - 1)
		return encode_raw(encodeSize, argv[optind], count);
	if (optind != argc - 1) {
		fprintf(stderr, "usage: jpegtime [-n N] FILE.jpg\n");
		return 2;
	}
	FILE* file = fopen(argv[optind], "rb");
	if (file == NULL)
		return 1;
	fseek(file, 0, SEEK_END);
	size_t size = ftell(file);
	fseek(file, 0, SEEK_SET);
	unsigned char* data = (unsigned char*)malloc(size);
	if (fread(data, 1, size, file) != size)
		return 1;
	fclose(file);

	unsigned width, height;
	size_t outSize = 0;
	{
		// the size first, for the output buffer
		jpeg_decompress_struct info;
		jpeg_error_mgr error;
		info.err = jpeg_std_error(&error);
		jpeg_create_decompress(&info);
		jpeg_mem_src(&info, data, size);
		jpeg_read_header(&info, TRUE);
		width = info.image_width;
		height = info.image_height;
		printf("JPEG %s: %ux%u, %zu bytes, %s, components %d, sampling %dx%d\n", argv[optind], width,
			height, size, info.progressive_mode ? "progressive" : "baseline", info.num_components,
			info.comp_info[0].h_samp_factor, info.comp_info[0].v_samp_factor);
		jpeg_destroy_decompress(&info);
	}
	unsigned char* out = (unsigned char*)malloc((size_t)(width + 64) * (height + 64) * 4);

	for (int raw = 0; raw < 2; raw++) {
		bigtime_t start = system_time();
		for (int i = 0; i < count; i++)
			decode(data, size, raw, out, &outSize, &width, &height);
		bigtime_t wall = system_time() - start;
		printf("JPEG libjpeg-turbo %s: %d in %.3f s, %.2f ms each (%.1f Mpixel/s), %zu bytes out\n",
			raw ? "raw YCbCr" : "BGRX", count, wall / 1e6, wall / 1e3 / count,
			(double)width * height * count / wall, outSize);
	}

	// (BTranslationUtils' file functions want a BApplication)
	BApplication app("application/x-vnd.haiku-pi-jpegtime");
	bigtime_t start = system_time();
	int good = 0;
	uint64 hash = 14695981039346656037ULL;
	for (int i = 0; i < count; i++) {
		BBitmap* bitmap = BTranslationUtils::GetBitmapFile(argv[optind]);
		if (bitmap != NULL && bitmap->IsValid()) {
			good++;
			if (i == count - 1) {
				// FNV-1a of the pixels: the same picture from another translator build?
				const uint8* bits = (const uint8*)bitmap->Bits();
				for (size_t b = 0; b < (size_t)bitmap->BitsLength(); b++)
					hash = (hash ^ bits[b]) * 1099511628211ULL;
			}
		}
		delete bitmap;
	}
	bigtime_t wall = system_time() - start;
	printf("JPEG translator (GetBitmapFile): %d of %d in %.3f s, %.2f ms each, pixels %016llx\n", good,
		count, wall / 1e6, wall / 1e3 / count, (unsigned long long)hash);
	return 0;
}
