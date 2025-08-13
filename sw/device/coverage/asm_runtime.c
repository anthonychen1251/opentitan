#include <stdint.h>

#include "sw/device/lib/base/macros.h"

#ifdef OT_COVERAGE_INSTRUMENTED

extern uint8_t __llvm_prf_cnts_start[];
extern uint8_t __llvm_prf_cnts_end[];

OT_NO_COVERAGE
uint32_t coverage_backup_asm_counters(uint32_t offset) {
  int32_t remaining = (int32_t)(__llvm_prf_cnts_end - __llvm_prf_cnts_start);
  uint32_t packed_byte = 0;
  for (uint8_t k = 0; k < 32 && remaining > 0; ++k, remaining--) {
    uint32_t bit = __llvm_prf_cnts_start[offset + k] == 0 ? 1 : 0;
    packed_byte |= (bit << k);
  }
  return packed_byte;
}

OT_NO_COVERAGE
void coverage_restore_asm_counters(uint32_t a, uint32_t b) {
  int32_t remaining = (int32_t)(__llvm_prf_cnts_end - __llvm_prf_cnts_start);
  for (int i=0; i<32 && remaining > 0; i++, remaining--) {
    if ((a >> i) & 1) {
      __llvm_prf_cnts_start[i] = 0;
    }
  }
  for (int i=0; i<32 && remaining > 0; i++, remaining--) {
    if ((b >> i) & 1) {
      __llvm_prf_cnts_start[i+32] = 0;
    }
  }
}

#endif
