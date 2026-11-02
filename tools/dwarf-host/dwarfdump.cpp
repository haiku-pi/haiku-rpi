/*
 * dwarfdump — a host (Linux) harness around Haiku Debugger's DWARF reader (src/kits/debugger/dwarf):
 * loads an ELF file the way the Debugger does (DwarfFile StartLoading/Load/FinishLoading) and prints
 * what the Debugger takes from it, independent of DWARF version and section offsets, so that the
 * output of a -gdwarf-4 and a -gdwarf-5 build of one program can be compared line by line:
 *
 *   per compilation unit: name, compilation directory, language, address ranges, file table, the
 *   line number program's rows (address, file, line, column, flags);
 *   per function (as DwarfImageDebugInfo::GetFunctions() finds them): qualified name, address ranges,
 *   declaration file and line, and its parameters and variables (lexical blocks included) with their
 *   locations evaluated at every row address of the function against a fake target (registers
 *   r<n> = 0x1000 * (n + 1), frame address 0x7f000000, memory unreadable).
 *
 *   dwarfdump [--summary] FILE
 *
 * --summary prints one line per unit (counts and a hash of the unit's full output) instead.
 * Build: tools/dwarf-host/build.sh HAIKU_TREE OUT_DIR.
 */


#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <set>
#include <string>
#include <vector>

#include <String.h>
#include <Variant.h>

#include "CfaContext.h"
#include "CompilationUnit.h"
#include "DebugInfoEntries.h"
#include "Dwarf.h"
#include "DwarfFile.h"
#include "DwarfTargetInterface.h"
#include "DwarfUtils.h"
#include "LineNumberProgram.h"
#include "SourceLanguageInfo.h"
#include "TargetAddressRangeList.h"
#include "ValueLocation.h"


static const target_addr_t kFrameAddress = 0x7f000000;


class FakeTarget : public DwarfTargetInterface {
public:
	virtual uint32 CountRegisters() const { return 128; }
	virtual uint32 RegisterValueType(uint32 index) const { return B_UINT64_TYPE; }

	virtual bool GetRegisterValue(uint32 index, BVariant& _value) const
	{
		if (index >= 128)
			return false;
		_value.SetTo((uint64)0x1000 * (index + 1));
		return true;
	}

	virtual bool SetRegisterValue(uint32 index, const BVariant& value) { return false; }
	virtual bool IsCalleePreservedRegister(uint32 index) const { return false; }
	virtual status_t InitRegisterRules(CfaContext& context) const { return B_OK; }
	virtual bool ReadMemory(target_addr_t address, void* buffer, size_t size) const
		{ return false; }
	virtual bool ReadValueFromMemory(target_addr_t address, uint32 valueType,
		BVariant& _value) const { return false; }
	virtual bool ReadValueFromMemory(target_addr_t addressSpace, target_addr_t address,
		uint32 valueType, BVariant& _value) const { return false; }
};


// Output goes to a std::string per unit, so that --summary can hash it.
static std::string sOut;


static void
out(const char* format, ...)
{
	char buffer[4096];
	va_list args;
	va_start(args, format);
	vsnprintf(buffer, sizeof(buffer), format, args);
	va_end(args);
	sOut += buffer;
}


static uint64
fnv1a(const std::string& text)
{
	uint64 hash = 0xcbf29ce484222325ULL;
	for (unsigned char c : text) {
		hash ^= c;
		hash *= 0x100000001b3ULL;
	}
	return hash;
}


static std::string
file_path(CompilationUnit* unit, int32 index)
{
	// index: one-based, as the line number program and DW_AT_decl_file use it
	const char* directory = NULL;
	const char* name = unit->FileAt(index - 1, &directory);
	if (name == NULL) {
		char buffer[32];
		snprintf(buffer, sizeof(buffer), "<file %" B_PRId32 ">", index);
		return buffer;
	}
	if (name[0] == '/' || directory == NULL)
		return name;
	return std::string(directory) + "/" + name;
}


static void
dump_ranges(TargetAddressRangeList* ranges, target_addr_t lowPC, target_addr_t highPC)
{
	if (ranges == NULL) {
		out(" [%#" B_PRIx64 "-%#" B_PRIx64 ")", lowPC, highPC);
		return;
	}
	for (int32 i = 0; i < ranges->CountRanges(); i++) {
		TargetAddressRange range = ranges->RangeAt(i);
		out(" [%#" B_PRIx64 "-%#" B_PRIx64 ")", range.Start(), range.End());
	}
}


static std::string
location_string(const ValueLocation& location)
{
	std::string result;
	char buffer[128];
	for (int32 i = 0; i < location.CountPieces(); i++) {
		ValuePieceLocation piece = location.PieceAt(i);
		switch (piece.type) {
			case VALUE_PIECE_LOCATION_INVALID:
				snprintf(buffer, sizeof(buffer), "invalid");
				break;
			case VALUE_PIECE_LOCATION_UNKNOWN:
				snprintf(buffer, sizeof(buffer), "unknown");
				break;
			case VALUE_PIECE_LOCATION_MEMORY:
				snprintf(buffer, sizeof(buffer), "mem %#" B_PRIx64, piece.address);
				break;
			case VALUE_PIECE_LOCATION_REGISTER:
				snprintf(buffer, sizeof(buffer), "reg %" B_PRIu32, piece.reg);
				break;
			case VALUE_PIECE_LOCATION_IMPLICIT:
			{
				int n = snprintf(buffer, sizeof(buffer), "value");
				const uint8* bytes = (const uint8*)piece.value;
				for (uint64 j = 0; bytes != NULL && j < piece.size && j < 16; j++)
					n += snprintf(buffer + n, sizeof(buffer) - n, " %02x", bytes[j]);
				break;
			}
		}
		if (i > 0)
			result += ", ";
		result += buffer;
		if (piece.size != 0 || piece.bitSize != 0) {
			snprintf(buffer, sizeof(buffer), " size %" B_PRIu64 " bits %" B_PRIu64,
				(uint64)piece.size, piece.bitSize);
			result += buffer;
		}
	}
	return result;
}


struct Context {
	DwarfFile*					file;
	CompilationUnit*			unit;
	FakeTarget*					target;
	std::vector<target_addr_t>	rowAddresses;	// sorted
	int32						functions;
	int32						variables;
	int32						resolved;
};


static void
dump_variable(Context& context, DIESubprogram* subprogram, DebugInfoEntry* entry,
	TargetAddressRangeList* ranges, target_addr_t lowPC, target_addr_t highPC, int depth)
{
	context.variables++;
	BString name;
	DwarfUtils::GetDIEName(entry, name);
	BString typeName;
	if (DIEVariable* variable = dynamic_cast<DIEVariable*>(entry)) {
		if (variable->GetType() != NULL)
			DwarfUtils::GetFullyQualifiedDIEName(variable->GetType(), typeName);
	} else if (DIEFormalParameter* parameter = dynamic_cast<DIEFormalParameter*>(entry)) {
		if (parameter->GetType() != NULL)
			DwarfUtils::GetFullyQualifiedDIEName(parameter->GetType(), typeName);
	}

	out("%*s%s %s : %s\n", depth * 2, "",
		entry->Tag() == DW_TAG_formal_parameter ? "param" : "var",
		name.String(), typeName.String());

	LocationDescription* location = entry->GetLocationDescription();
	if (location == NULL || !location->IsValid()) {
		out("%*s  no location\n", depth * 2, "");
		return;
	}

	// evaluate at every row address inside the function's ranges; print changes only
	std::string last;
	for (target_addr_t address : context.rowAddresses) {
		bool inside = false;
		if (ranges != NULL)
			inside = ranges->Contains(address);
		else
			inside = address >= lowPC && address < highPC;
		if (!inside)
			continue;

		ValueLocation result;
		status_t error = context.file->ResolveLocation(context.unit, 8, false,
			subprogram, location, context.target, address, 0, false,
			kFrameAddress, 0, result);
		std::string text;
		if (error != B_OK) {
			char buffer[64];
			snprintf(buffer, sizeof(buffer), "error %s", strerror(error));
			text = buffer;
		} else {
			text = location_string(result);
			context.resolved++;
		}
		if (text != last) {
			out("%*s  @%#" B_PRIx64 ": %s\n", depth * 2, "", address, text.c_str());
			last = text;
		}
	}
}


static void
dump_block(Context& context, DIESubprogram* subprogram, const DebugInfoEntryList& variables,
	const DebugInfoEntryList& blocks, TargetAddressRangeList* ranges, target_addr_t lowPC,
	target_addr_t highPC, int depth)
{
	for (DebugInfoEntryList::ConstIterator it = variables.GetIterator();
			DebugInfoEntry* entry = it.Next();) {
		dump_variable(context, subprogram, entry, ranges, lowPC, highPC, depth);
	}

	for (DebugInfoEntryList::ConstIterator it = blocks.GetIterator();
			DebugInfoEntry* entry = it.Next();) {
		DIELexicalBlock* block = dynamic_cast<DIELexicalBlock*>(entry);
		if (block == NULL)
			continue;
		TargetAddressRangeList* blockRanges = context.file->ResolveRangeList(context.unit,
			block->AddressRangesOffset());
		out("%*sblock", depth * 2, "");
		dump_ranges(blockRanges, block->LowPC(), block->HighPC());
		out("\n");
		dump_block(context, subprogram, block->Variables(), block->Blocks(), blockRanges,
			block->LowPC(), block->HighPC(), depth + 1);
		if (blockRanges != NULL)
			blockRanges->ReleaseReference();
	}
}


static void
dump_function(Context& context, DIESubprogram* subprogram)
{
	// as DwarfImageDebugInfo::_AddFunction()
	if (subprogram->IsDeclaration() || subprogram->Inline() == DW_INL_inlined
		|| subprogram->Inline() == DW_INL_declared_inlined) {
		return;
	}

	BString name;
	DwarfUtils::GetFullyQualifiedDIEName(subprogram, name);
	if (name.Length() == 0)
		return;

	TargetAddressRangeList* ranges = context.file->ResolveRangeList(context.unit,
		subprogram->AddressRangesOffset());
	if (ranges == NULL && subprogram->HighPC() <= subprogram->LowPC())
		return;

	context.functions++;
	out("  function %s", name.String());
	dump_ranges(ranges, subprogram->LowPC(), subprogram->HighPC());

	const char* directory = NULL;
	const char* fileName = NULL;
	int32 line = -1;
	int32 column = -1;
	if (DwarfUtils::GetDeclarationLocation(context.file, subprogram, directory, fileName,
			line, column)) {
		out(" decl %s%s%s:%" B_PRId32, directory != NULL && fileName[0] != '/' ? directory : "",
			directory != NULL && fileName[0] != '/' ? "/" : "", fileName, line);
	}
	out("\n");

	dump_block(context, subprogram, subprogram->Parameters(), DebugInfoEntryList(), ranges,
		subprogram->LowPC(), subprogram->HighPC(), 2);
	dump_block(context, subprogram, subprogram->Variables(), subprogram->Blocks(), ranges,
		subprogram->LowPC(), subprogram->HighPC(), 2);

	if (ranges != NULL)
		ranges->ReleaseReference();
}


static void
dump_namespace(Context& context, const DebugInfoEntryList& children)
{
	// as DwarfImageDebugInfo::GetFunctions() / _RecursiveTraverseNamespaceForFunctions()
	for (DebugInfoEntryList::ConstIterator it = children.GetIterator();
			DebugInfoEntry* entry = it.Next();) {
		if (entry->Tag() == DW_TAG_subprogram)
			dump_function(context, static_cast<DIESubprogram*>(entry));

		if (DIENamespace* nsEntry = dynamic_cast<DIENamespace*>(entry)) {
			dump_namespace(context, nsEntry->Children());
			continue;
		}

		if (DIEClassBaseType* classEntry = dynamic_cast<DIEClassBaseType*>(entry)) {
			for (DebugInfoEntryList::ConstIterator it
						= classEntry->MemberFunctions().GetIterator();
					DebugInfoEntry* memberEntry = it.Next();) {
				dump_function(context, static_cast<DIESubprogram*>(memberEntry));
			}
		}
	}
}


int
main(int argc, char** argv)
{
	bool summary = false;
	int arg = 1;
	if (arg < argc && strcmp(argv[arg], "--summary") == 0) {
		summary = true;
		arg++;
	}
	if (arg + 1 != argc) {
		fprintf(stderr, "usage: %s [--summary] FILE\n", argv[0]);
		return 2;
	}
	const char* path = argv[arg];

	DwarfFile* file = new DwarfFile;
	BString externalFile;
	status_t error = file->StartLoading(path, externalFile);
	if (error == B_OK)
		error = file->Load(8, false, BString());
	if (error == B_OK)
		error = file->FinishLoading(8, false);
	printf("file %s: load %s, %" B_PRId32 " units\n", path, strerror(error),
		file->CountCompilationUnits());

	FakeTarget target;
	int32 totalFunctions = 0, totalVariables = 0, totalRows = 0;
	for (int32 i = 0; CompilationUnit* unit = file->CompilationUnitAt(i); i++) {
		sOut.clear();
		DIECompileUnitBase* unitEntry = unit->UnitEntry();
		out("unit %" B_PRId32 ": %s\n", i, unitEntry->Name());
		out("  dir %s, language %s (%u)\n", unitEntry->CompilationDir(),
			unit->SourceLanguage() != NULL ? unit->SourceLanguage()->name : "-",
			unitEntry->Language());
		out("  ranges");
		dump_ranges(unit->AddressRanges(), unitEntry->LowPC(), unitEntry->HighPC());
		out("\n");
		for (int32 j = 0; j < unit->CountFiles(); j++)
			out("  file %" B_PRId32 ": %s\n", j + 1, file_path(unit, j + 1).c_str());

		Context context = { file, unit, &target, {}, 0, 0, 0 };
		int32 rows = 0;
		LineNumberProgram& program = unit->GetLineNumberProgram();
		if (program.IsValid()) {
			std::set<target_addr_t> addresses;
			LineNumberProgram::State state;
			program.GetInitialState(state);
			while (program.GetNextRow(state)) {
				rows++;
				out("  row %#" B_PRIx64 " %s:%" B_PRId32 ":%" B_PRId32 "%s%s%s\n",
					state.address, file_path(unit, state.file).c_str(), state.line,
					state.column, state.isStatement ? " stmt" : "",
					state.isSequenceEnd ? " end" : "",
					state.isPrologueEnd ? " prologue_end" : "");
				if (!state.isSequenceEnd)
					addresses.insert(state.address);
			}
			context.rowAddresses.assign(addresses.begin(), addresses.end());
		} else
			out("  no line number program\n");

		dump_namespace(context, unitEntry->OtherChildren());

		totalFunctions += context.functions;
		totalVariables += context.variables;
		totalRows += rows;
		if (summary) {
			printf("unit %" B_PRId32 ": %s: %" B_PRId32 " files, %" B_PRId32 " rows, %"
				B_PRId32 " functions, %" B_PRId32 " variables (%" B_PRId32 " locations),"
				" hash %016" B_PRIx64 "\n", i, unitEntry->Name(), unit->CountFiles(), rows,
				context.functions, context.variables, context.resolved, fnv1a(sOut));
		} else
			fputs(sOut.c_str(), stdout);
	}
	printf("total: %" B_PRId32 " rows, %" B_PRId32 " functions, %" B_PRId32 " variables\n",
		totalRows, totalFunctions, totalVariables);

	file->ReleaseReference();
	return 0;
}
