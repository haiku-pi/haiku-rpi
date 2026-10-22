/*
 * User reads (MRS) of the arm64 ID registers, which the kernel emulates as Linux does: an ARMv8.0 CPU
 * makes them an undefined instruction. Programs read the CPU's features this way (Wine's processor
 * registry keys, which FEX reads; Box64; FEX).
 *
 * Build: aarch64-unknown-haiku-gcc -O2 -o id-regs id-regs.c
 * Prints the registers and PASS (MIDR_EL1 names an Arm CPU, MPIDR_EL1 reads as a uniprocessor's, a
 * register into x30 and into xzr works), or FAIL. Without the emulation it dies of SIGILL.
 */

#include <stdio.h>
#include <stdint.h>

#define MRS(name, value) __asm__ __volatile__("mrs %0, " name : "=r"(value))

int main(void)
{
	uint64_t midr, mpidr, pfr0, pfr1, dfr0, isar0, isar1, isar2, mmfr0, mmfr1, mmfr2, unallocated, lr;
	int ok;

	MRS("midr_el1", midr);
	MRS("mpidr_el1", mpidr);
	MRS("s3_0_c0_c4_0", pfr0);
	MRS("s3_0_c0_c4_1", pfr1);
	MRS("s3_0_c0_c5_0", dfr0);
	MRS("s3_0_c0_c6_0", isar0);
	MRS("s3_0_c0_c6_1", isar1);
	MRS("s3_0_c0_c6_2", isar2);
	MRS("s3_0_c0_c7_0", mmfr0);
	MRS("s3_0_c0_c7_1", mmfr1);
	MRS("s3_0_c0_c7_2", mmfr2);
	MRS("s3_0_c0_c3_7", unallocated);
	/* the target registers the iframe keeps apart: x30 (lr) and xzr */
	__asm__ __volatile__("mrs x30, midr_el1\n\tmov %0, x30" : "=r"(lr) :: "x30");
	__asm__ __volatile__("mrs xzr, midr_el1");

	printf("MIDR_EL1         %#018llx\n", (unsigned long long)midr);
	printf("MPIDR_EL1        %#018llx\n", (unsigned long long)mpidr);
	printf("ID_AA64PFR0_EL1  %#018llx\n", (unsigned long long)pfr0);
	printf("ID_AA64PFR1_EL1  %#018llx\n", (unsigned long long)pfr1);
	printf("ID_AA64DFR0_EL1  %#018llx\n", (unsigned long long)dfr0);
	printf("ID_AA64ISAR0_EL1 %#018llx\n", (unsigned long long)isar0);
	printf("ID_AA64ISAR1_EL1 %#018llx\n", (unsigned long long)isar1);
	printf("ID_AA64ISAR2_EL1 %#018llx\n", (unsigned long long)isar2);
	printf("ID_AA64MMFR0_EL1 %#018llx\n", (unsigned long long)mmfr0);
	printf("ID_AA64MMFR1_EL1 %#018llx\n", (unsigned long long)mmfr1);
	printf("ID_AA64MMFR2_EL1 %#018llx\n", (unsigned long long)mmfr2);
	printf("S3_0_C0_C3_7     %#018llx (unallocated)\n", (unsigned long long)unallocated);

	ok = (midr >> 24) == 0x41 && mpidr == 1ULL << 31 && lr == midr && unallocated == 0;
	printf("%s\n", ok ? "PASS" : "FAIL");
	return ok ? 0 : 1;
}
