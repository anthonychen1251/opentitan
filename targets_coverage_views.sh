# COVERAGE_VIEW_CWT=(
#     "//sw/device/silicon_creator/rom_ext/sival:rom_ext_prod_dice_cwt_spidfu_coverage_view"
#     "//sw/device/silicon_creator/rom_ext/imm_section:imm_section_dice_cwt_coverage_view"
#     # "//sw/device/silicon_creator/rom:instrumented_mask_rom_coverage_view"
# )

COVERAGE_VIEW_X509=(
    # "//sw/device/silicon_creator/rom_ext/sival:rom_ext_prod_dice_x509_xmodem_coverage_view"
 #   "//sw/device/silicon_creator/rom_ext/sival:rom_ext_prod_dice_x509_usbdfu_coverage_view"
#   "//sw/device/silicon_creator/rom_ext/imm_section:imm_section_dice_x509_coverage_view"
    # "//sw/device/silicon_creator/rom:instrumented_mask_rom_coverage_view"
)

COVERAGE_VIEW_MLDSA=(
    "//sw/device/silicon_creator/rom_ext/sival:rom_ext_prod_dice_mldsa_usbdfu_coverage_view"
    "//sw/device/silicon_creator/rom_ext/imm_section:imm_section_dice_mldsa_coverage_view"
    # "//sw/device/silicon_creator/rom:instrumented_mask_rom_coverage_view"
)

COVERAGE_VIEW_GROUPS=(
    # "COVERAGE_VIEW_CWT"
    # "COVERAGE_VIEW_X509"
    "COVERAGE_VIEW_MLDSA"
)
