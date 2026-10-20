/*
 * Copyright 2026, Haiku, Inc. All rights reserved.
 * Distributed under the terms of the MIT License.
 */
#ifndef AVCODEC_RPIVID_CMD_H
#define AVCODEC_RPIVID_CMD_H


/*	The BCM2711 rpivid HEVC block's phase-1 command buffer.

	Phase 1 executes a list of 64-bit entries, a register offset in the low
	word and its value in the high word: the parameter sets, each slice
	segment's messages and data, and one entry point per tile or wavefront
	row. This turns parsed parameters - shaped like the V4L2 stateless HEVC
	controls, filled from any HEVC parser - into those entries, in the order
	the Raspberry Pi Linux driver (hevc_dec) emits them. Bitstream addresses
	are byte offsets into the caller's bitstream buffer (the rpivid driver
	rebases them), so this has no hardware or OS dependency (but for
	libavutil's AVERROR).
*/


#include <stddef.h>
#include <stdint.h>


#define RPIVID_MAX_TILE_COLUMNS		20
#define RPIVID_MAX_TILE_ROWS		22
#define RPIVID_SCALING_FACTOR_BYTES	4064
#define RPIVID_MAX_SLICE_MESSAGES	259

enum {
	RPIVID_SLICE_B = 0,
	RPIVID_SLICE_P = 1,
	RPIVID_SLICE_I = 2,
};


/* Per picture: what SPS and PPS give the block */
typedef struct RpividPictureParams {
	uint32_t	width;
	uint32_t	height;
	uint8_t		bit_depth;		/* luma and chroma: 8 or 10 */
	uint8_t		chroma_format_idc;
	uint8_t		log2_min_cb_size;
	uint8_t		log2_ctb_size;
	uint8_t		log2_min_tb_size;
	uint8_t		log2_max_tb_size;
	uint8_t		max_transform_depth_intra;
	uint8_t		max_transform_depth_inter;
	uint8_t		amp;
	uint8_t		strong_intra_smoothing;
	uint8_t		scaling_list;
	uint8_t		pcm;
	uint8_t		pcm_bit_depth;
	uint8_t		pcm_bit_depth_chroma;
	uint8_t		log2_min_pcm_cb_size;
	uint8_t		log2_max_pcm_cb_size;
	uint8_t		pcm_loop_filter_disabled;

	uint8_t		cu_qp_delta;
	uint8_t		diff_cu_qp_delta_depth;
	uint8_t		transquant_bypass;
	uint8_t		transform_skip;
	uint8_t		sign_data_hiding;
	uint8_t		constrained_intra_pred;
	int8_t		cb_qp_offset;
	int8_t		cr_qp_offset;
	uint8_t		weighted_pred;
	uint8_t		weighted_bipred;
	uint8_t		entropy_coding_sync;
	uint8_t		tiles;
	uint8_t		loop_filter_across_tiles;
	uint8_t		log2_parallel_merge_level;
	uint32_t	tile_columns;	/* 1 without tiles */
	uint32_t	tile_rows;
	uint32_t	column_bd[RPIVID_MAX_TILE_COLUMNS + 1];
		/* tile boundaries in CTBs; column_bd[tile_columns] = width in CTBs */
	uint32_t	row_bd[RPIVID_MAX_TILE_ROWS + 1];
	const int*	ctb_addr_rs_to_ts;	/* NULL without tiles */
	const int*	ctb_addr_ts_to_rs;

	const uint8_t* scaling_factors;
		/* RPIVID_SCALING_FACTOR_BYTES (ff_rpivid_scaling_factors()), or NULL */

	uint8_t		slice_temporal_mvp;
		/* slice_temporal_mvp_enabled_flag, the same in all of a picture's
		   slices */
	uint8_t		one_slice_segment;
		/* the picture is a single slice segment */
} RpividPictureParams;


/* Per slice segment */
typedef struct RpividSliceParams {
	uint32_t	data_offset;
		/* of slice_segment_data() in the bitstream buffer, bytes */
	uint32_t	data_size;
		/* bytes of slice data, emulation prevention bytes included */
	uint32_t	segment_address;	/* first CTB, raster scan */
	uint8_t		dependent;
	uint8_t		type;				/* RPIVID_SLICE_* */
	int			qp;					/* SliceQpY */
	int8_t		cb_qp_offset;
	int8_t		cr_qp_offset;
	uint8_t		sao_luma;
	uint8_t		sao_chroma;
	uint8_t		mvd_l1_zero;
	uint8_t		cabac_init;
	uint8_t		collocated_from_l0;
	uint8_t		max_num_merge_cand;	/* 0 for I slices */
	uint8_t		num_refs[2];
	uint8_t		ref_slot[2][16];	/* the phase-2 reference slot of each */
	int32_t		ref_poc[2][16];
	uint8_t		ref_long_term[2][16];
	int32_t		poc;
	uint8_t		weighted;			/* a pred_weight_table() applies */
	uint8_t		luma_log2_weight_denom;
	uint8_t		chroma_log2_weight_denom;
	int16_t		luma_weight[2][16];		/* LumaWeightLX */
	int16_t		luma_offset[2][16];		/* luma_offset_lX */
	int16_t		chroma_weight[2][16][2];	/* ChromaWeightLX */
	int16_t		chroma_offset[2][16][2];	/* ChromaOffsetLX */
	int8_t		beta_offset_div2;
	int8_t		tc_offset_div2;
	uint8_t		deblocking_disabled;
	uint8_t		loop_filter_across_slices;
} RpividSliceParams;


typedef struct RpividCommands {
	uint64_t*	entries;
	uint32_t	count;
	uint32_t	capacity;
	int			error;			/* sticky: a negative AVERROR */

	const RpividPictureParams* picture;
	uint32_t	ctb_width;
	uint32_t	ctb_height;
	uint32_t	slice_index;
	uint32_t	slice_start;	/* SLICESTART of the last independent segment */

	/* the last entry point (tile or wavefront row) */
	uint32_t	entry_tile_x;
	uint32_t	entry_tile_y;
	uint32_t	entry_ctb_x;
	uint32_t	entry_ctb_y;
	int			entry_qp;
	uint32_t	entry_slice;

	/* the slice segment being added */
	uint32_t	start_ts;
	uint32_t	start_ctb_x;
	uint32_t	start_ctb_y;
	uint32_t	previous_ctb_x;	/* the last CTB of the previous segment */
	uint32_t	previous_ctb_y;

	uint16_t	messages[RPIVID_MAX_SLICE_MESSAGES];
	uint32_t	message_count;
} RpividCommands;


void		ff_rpivid_commands_init(RpividCommands* commands);
void		ff_rpivid_commands_free(RpividCommands* commands);

/* Starts a picture; \a picture must stay valid until ..._end(). */
void		ff_rpivid_commands_begin(RpividCommands* commands,
				const RpividPictureParams* picture);
/* The picture's next slice segment, in decoding order. 0 or a negative
   AVERROR. */
int			ff_rpivid_commands_add_slice(RpividCommands* commands,
				const RpividSliceParams* slice);
/* Closes the picture. The number of entries, or a negative AVERROR. */
int			ff_rpivid_commands_end(RpividCommands* commands);

/* The phase-2 CONFIG2 register: write_mv = keep this picture's motion vectors
   (a later picture may use it as its collocated one) */
uint32_t	ff_rpivid_config2(const RpividPictureParams* picture, int write_mv);

/* The block's scaling factor array from HEVC scaling lists in raster order:
   4x4 [6][16], 8x8 [6][64], 16x16 [6][64] + DC, 32x32 (intra and inter
   luma) [2][64] + DC */
void		ff_rpivid_scaling_factors(uint8_t out[RPIVID_SCALING_FACTOR_BYTES],
				const uint8_t list4x4[6][16], const uint8_t list8x8[6][64],
				const uint8_t list16x16[6][64], const uint8_t dc16x16[6],
				const uint8_t list32x32[2][64], const uint8_t dc32x32[2]);


#endif /* AVCODEC_RPIVID_CMD_H */
