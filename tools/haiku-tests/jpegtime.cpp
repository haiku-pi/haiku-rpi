/*
 * jpegtime — the CPU's JPEG decoding, the baseline for the VideoCore's (mmal-codec jpegdec;
 * docs/design/videocore-services.md):
 *
 *   jpegtime [-n N] FILE.jpg
 *
 * N times each (default 5): libjpeg-turbo (the system's libjpeg) to BGRX, i.e. B_RGB32, as one call per
 * picture (the decoding alone, the file in memory); libjpeg-turbo to its raw planar YCbCr (no colour
 * conversion: what the VideoCore's I420 output corresponds to); and BTranslationUtils::GetBitmap() on
 * the file (Haiku's JPEG translator, what ShowImage and other applications get). Lines "JPEG ...".
 *
 * Copyright 2026, Haiku-Pi project. Distributed under the terms of the MIT License.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

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


int
main(int argc, char** argv)
{
	int count = 5, opt;
	while ((opt = getopt(argc, argv, "n:")) != -1) {
		if (opt == 'n')
			count = atoi(optarg);
		else
			return 2;
	}
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

	bigtime_t start = system_time();
	int good = 0;
	for (int i = 0; i < count; i++) {
		BBitmap* bitmap = BTranslationUtils::GetBitmap(argv[optind]);
		if (bitmap != NULL && bitmap->IsValid())
			good++;
		delete bitmap;
	}
	bigtime_t wall = system_time() - start;
	printf("JPEG translator (GetBitmap from the file): %d of %d in %.3f s, %.2f ms each\n", good, count,
		wall / 1e6, wall / 1e3 / count);
	return 0;
}
