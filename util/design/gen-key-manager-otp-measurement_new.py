#!/usr/bin/env python3
# Copyright lowRISC contributors (OpenTitan project).
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0
r"""Generate ROT creator authentication data from JSON file.


The script will generate the ROT creator authentication data and update the JSON
file with the generated ROT_CREATOR_AUTH_CODESIGN_BLOCK_SHA2_256_HASH.
"""

import argparse
import binascii
import hjson
import json
import logging

from Crypto.Hash import SHA256
from lib.OtpMemImg import OtpMemImg
from pathlib import Path


_DIGEST_SUFFIX_STR = "_DIGEST"

_CREATOR_SW_CFG_PARTITION_NAME = "CREATOR_SW_CFG"
_OWNER_SW_CFG_PARTITION_NAME = "OWNER_SW_CFG"
_ROT_CREATOR_AUTH_PARTITION_NAME = "ROT_CREATOR_AUTH_CODESIGN"
_ROT_CREATOR_AUTH_DIGEST_FIELD_NAME = "ROT_CREATOR_AUTH_CODESIGN_BLOCK_SHA2_256_HASH"

# Get the memory map definition.
MMAP_DEFINITION_FILE = 'hw/ip/otp_ctrl/data/otp_ctrl_mmap.hjson'
# Life cycle state and ECC poly definitions.
LC_STATE_DEFINITION_FILE = 'hw/ip/lc_ctrl/data/lc_ctrl_state.hjson'
# Default image file definition (can be overridden on the command line).
IMAGE_DEFINITION_FILE = 'hw/ip/otp_ctrl/data/otp_ctrl_img_dev.hjson'

class KeyManagerOtpMeasurement:

    def __init__(self, img: OtpMemImg):
        self.otp_mem_img = img

    def calculate_partition_digest(self, partition_name):
        part = self.otp_mem_img.get_part(partition_name)
        digest_name = partition_name + _DIGEST_SUFFIX_STR
        digest_item = self.otp_mem_img.get_item(partition_name, digest_name)
        digest_size = digest_item["size"]
        part_data, _ = self.otp_mem_img.streamout_partition(part)
        data_len = len(part_data) - digest_size

        return SHA256.new(bytes(part_data[:data_len])).digest()

    def get_rot_creator_auth(self):
        part = self.otp_mem_img.get_part(_ROT_CREATOR_AUTH_PARTITION_NAME)
        digest_name = _ROT_CREATOR_AUTH_DIGEST_FIELD_NAME
        digest_item = self.otp_mem_img.get_item(_ROT_CREATOR_AUTH_PARTITION_NAME, digest_name)
        # print(digest_item)
        # print(part)
        digest_size = digest_item["size"]
        part_data, part_annotation = self.otp_mem_img.streamout_partition(part)
        empty_list = []
        # print(part_annotation)
        for val, name in zip(part_data, part_annotation):
            if _ROT_CREATOR_AUTH_DIGEST_FIELD_NAME in name:
                empty_list.append(val)
        # data_len = len(part_data) - digest_size
        # print(empty_list)
        # return SHA256.new(bytes(part_data[:data_len])).digest()
        # empty_list.reverse()
        return bytes(empty_list)


def main() -> None:
    logging.basicConfig(level=logging.WARNING, format="%(levelname)s: %(message)s")
    # Make sure the script can also be called from other dirs than
    # just the project root by adapting the default paths accordingly.
    proj_root = Path(__file__).parent.joinpath('../../')
    proj_root = Path(__file__).parent.joinpath('../../')
    lc_state_def_file = Path(proj_root).joinpath(LC_STATE_DEFINITION_FILE)
    mmap_def_file = Path(proj_root).joinpath(MMAP_DEFINITION_FILE)
    img_def_file = Path(proj_root).joinpath(IMAGE_DEFINITION_FILE)
    parser = argparse.ArgumentParser(
        prog="gen-key-manager-otp-measurement",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)

    parser.add_argument('--lc-state-def',
                        type=Path,
                        metavar='<path>',
                        default=lc_state_def_file,
                        help='''
                        Life cycle state definition file in Hjson format.
                        ''')

    parser.add_argument('--mmap-def',
                        type=Path,
                        metavar='<path>',
                        default=mmap_def_file,
                        help='''
                        OTP memory map file in Hjson format.
                        ''')

    parser.add_argument('--img-cfg',
                        type=Path,
                        metavar='<path>',
                        default=img_def_file,
                        help='''
                        Image configuration file in Hjson format.
                        Defaults to {}
                        '''.format(img_def_file))

    parser.add_argument('--add-cfg',
                        type=Path,
                        metavar='<path>',
                        action='extend',
                        nargs='+',
                        default=[],
                        help='''
                        Additional image configuration file in Hjson format.

                        This switch can be specified multiple times.
                        Image configuration files are parsed in the same
                        order as they are specified on the command line,
                        and partition item values that are specified multiple
                        times are overridden in that order.

                        Note that seed values in additional configuration files
                        are ignored.
                        ''')

    args = parser.parse_args()

    with open(args.lc_state_def, 'r') as infile:
        lc_state_cfg = hjson.load(infile)
    with open(args.mmap_def, 'r') as infile:
        otp_mmap_cfg = hjson.load(infile)
    with open(args.img_cfg, 'r') as infile:
        img_cfg = hjson.load(infile)

    try:
        otp_mem_img = OtpMemImg(lc_state_cfg, otp_mmap_cfg, img_cfg, None)
        for f in args.add_cfg:
            logging.info(f)
            with open(f, 'r') as infile:
                cfg = hjson.load(infile)
                otp_mem_img.override_data(cfg)

    except RuntimeError as err:
        logging.error(err)
        exit(1)

    partition_parser = KeyManagerOtpMeasurement(otp_mem_img)
    creator_sw_cfg_digset = partition_parser.calculate_partition_digest(_CREATOR_SW_CFG_PARTITION_NAME)
    owner_sw_cfg_digset = partition_parser.calculate_partition_digest(_OWNER_SW_CFG_PARTITION_NAME)

    print(creator_sw_cfg_digset.hex())
    print(owner_sw_cfg_digset.hex())
    print(partition_parser.get_rot_creator_auth().hex())
    tmp = partition_parser.get_rot_creator_auth()
    bin_data = b'\x00' * (16)

    print(SHA256.new(bin_data+tmp).digest().hex())
    print(creator_sw_cfg_digset[-4:].hex())
    print(creator_sw_cfg_digset[-8:-4].hex())
    c = list(creator_sw_cfg_digset[-8:])
    c.reverse()
    o = list(owner_sw_cfg_digset[-8:])
    o.reverse()
    print("Final OTP measurment:")
    print(SHA256.new(bytes(c)+bytes(o)+tmp).digest().hex())

if __name__ == "__main__":
    main()
