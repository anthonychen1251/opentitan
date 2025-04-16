/* Sections for LLVM profiling. */

SECTIONS {
  __llvm_prf_cnts : AT(0x0) ALIGN(8) {
    __llvm_prf_cnts_start = .;
    KEEP(*(__llvm_prf_cnts))
    __llvm_prf_cnts_end = .;

    ASSERT(
      _stack_start > ABSOLUTE(.),
      "Allocated RAM overflow to stack region");

  } > ram_main

  /DISCARD/ : {
      *(.init_array)
      *(.init_array.*)
  }

  __llvm_prf_data 0x0 (INFO) : ALIGN(8) {
    __llvm_prf_data_start = .;
    KEEP(*(__llvm_prf_data))
    __llvm_prf_data_end = .;
  }

  __llvm_prf_names 0x0 (INFO) : ALIGN(8) {
    __llvm_prf_names_start = .;
    KEEP(*(__llvm_prf_names))
    __llvm_prf_names_end = .;
  }
}
