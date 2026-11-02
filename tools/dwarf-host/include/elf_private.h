/* elf_private.h — host stand-in for Haiku's headers/private/system/elf_private.h: the 64-bit ELF types. */
#ifndef DWARF_HOST_ELF_PRIVATE_H
#define DWARF_HOST_ELF_PRIVATE_H

#include <os/kernel/elf.h>
#include <SupportDefs.h>

typedef Elf64_Addr elf_addr;
typedef Elf64_Ehdr elf_ehdr;
typedef Elf64_Phdr elf_phdr;
typedef Elf64_Shdr elf_shdr;
typedef Elf64_Sym elf_sym;
typedef Elf64_Dyn elf_dyn;
typedef uint16 elf_versym;

#endif
