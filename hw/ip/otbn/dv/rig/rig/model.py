# Copyright lowRISC contributors (OpenTitan project).
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

import math
import random
from typing import Dict, List, Optional, Set, Tuple

from shared.operand import (OperandType, EnumOperandType,
                            ImmOperandType, OptionOperandType, RegOperandType)

from .known_mem import KnownMem
from .program import ProgInsn

# A dictionary mapping integers to weights
WDict = Dict[int, float]


class CallStack:
    '''An abstract model of the x1 call stack'''
    def __init__(self) -> None:
        self._min_depth = 0
        self._max_depth = 0
        self._elts_at_top = []  # type: List[Optional[int]]

    def copy(self) -> 'CallStack':
        '''Return a deep copy of the call stack'''
        ret = CallStack()
        ret._min_depth = self._min_depth
        ret._max_depth = self._max_depth
        ret._elts_at_top = self._elts_at_top.copy()
        return ret

    def merge(self, other: 'CallStack') -> None:
        self._min_depth = min(self._min_depth, other._min_depth)
        self._max_depth = max(self._max_depth, other._max_depth)
        new_top = []
        for a, b in zip(reversed(self._elts_at_top),
                        reversed(other._elts_at_top)):
            if a == b:
                new_top.append(a)
            else:
                break
        new_top.reverse()
        self._elts_at_top = new_top
        assert self._min_depth <= self._max_depth
        assert len(self._elts_at_top) <= self._max_depth

    def empty(self) -> bool:
        assert 0 <= self._min_depth
        return self._min_depth == 0

    def full(self) -> bool:
        assert self._max_depth <= 8
        return self._max_depth == 8

    def depth_range(self) -> Tuple[int, int]:
        '''Return the (inclusive) range of possible depths'''
        return (self._min_depth, self._max_depth)

    def pop(self) -> None:
        assert 0 < self._min_depth
        self._min_depth -= 1
        self._max_depth -= 1
        if self._elts_at_top:
            self._elts_at_top.pop()

    def peek(self) -> Optional[int]:
        assert 0 < self._min_depth
        return self._elts_at_top[-1] if self._elts_at_top else None

    def write(self, value: Optional[int], update: bool) -> None:
        '''Write a value to the call stack.

        The update flag works as described for Model.write_reg

        '''
        if update:
            # If we're updating a write to x1, check that the new value refines
            # the top of the call stack.
            assert self._min_depth > 0
            if self._elts_at_top:
                assert self._elts_at_top[-1] in [None, value]
                self._elts_at_top[-1] = value
            else:
                self._elts_at_top.append(value)
        else:
            assert not self.full()
            self._min_depth += 1
            self._max_depth += 1
            self._elts_at_top.append(value)

    def forget_value(self) -> None:
        '''Replace any known values with None'''
        self._elts_at_top = [None] * len(self._elts_at_top)


class LoopStack:
    '''An abstract model of the loop stack

    The idea is that most of the time, we push loop end addresses onto _stack
    when entering a loop body and pop them off again when exiting. If something
    goes wrong in the loop body and the pop address doesn't match, we throw
    away the current stack (since we know it can never be popped) and increment
    a "stuck" counter by that much.

    This "stuck" counter, in turn, needs to be a range of possible values
    because otherwise we can't merge branches (where one side might have had an
    ill-formed loop, but the other didn't).

    '''
    stack_depth = 8

    def __init__(self) -> None:
        self._stack = []  # type: List[int]
        self._min_stuck = 0
        self._max_stuck = 0

    def copy(self) -> 'LoopStack':
        '''Return a deep copy of the loop stack'''
        ret = LoopStack()
        ret._stack = self._stack.copy()
        ret._min_stuck = self._min_stuck
        ret._max_stuck = self._max_stuck
        return ret

    def merge(self, other: 'LoopStack') -> None:
        if self._stack == other._stack:
            matching_stack = self._stack
            ns_min = 0
            ns_max = 0
        else:
            matching_stack = []
            for a, b in zip(self._stack, other._stack):
                if a == b:
                    matching_stack.append(a)
                else:
                    break
            new_stuck_self = len(self._stack) - len(matching_stack)
            new_stuck_other = len(other._stack) - len(matching_stack)
            ns_min = min(new_stuck_self, new_stuck_other)
            ns_max = max(new_stuck_self, new_stuck_other)

        self._stack = matching_stack
        self._min_stuck = min(self._min_stuck, other._min_stuck) + ns_min
        self._max_stuck = max(self._max_stuck, other._max_stuck) + ns_max

    def push(self, end_addr: int) -> None:
        assert self._max_stuck + len(self._stack) < LoopStack.stack_depth
        self._stack.append(end_addr)

    def pop(self, end_addr: int) -> None:
        if self._stack:
            exp_addr = self._stack.pop()
            if exp_addr != end_addr:
                to_add = len(self._stack) + 1
                self._min_stuck += to_add
                self._max_stuck += to_add
                self._stack = []

    def min_depth(self) -> int:
        return self._min_stuck + len(self._stack)

    def max_depth(self) -> int:
        return self._max_stuck + len(self._stack)

    def maybe_full(self) -> bool:
        return self.max_depth() == LoopStack.stack_depth

    def force_full(self) -> None:
        '''Make the loop stack look like it's completely full'''
        self._stack = []
        self._min_stuck = LoopStack.stack_depth
        self._max_stuck = LoopStack.stack_depth


class Model:
    '''An abstract model of the processor and memories

    This definitely doesn't try to act as a simulator. Rather, it tracks what
    registers and locations in memory are guaranteed have defined values after
    following the instruction stream to this point.

    '''
    def __init__(self, dmem_size: int, fuel: int) -> None:
        assert fuel >= 0
        self.initial_fuel = fuel
        self.fuel = fuel

        self.dmem_size = dmem_size

        # Known values for registers. This is a dictionary mapping register
        # type to a dictionary of known registers of that type. The register
        # type is a string matching the formats in RegOperandType.TYPE_FMTS.
        # The value for a type is another dictionary, mapping register index to
        # an Optional[int]. If the value is a number, the register value is
        # known to currently equal that number. If it is None, the register
        # value is unknown (but the register does have an architectural value).
        #
        # Note that x1 behaves a bit strangely because of the call stack rules,
        # so we don't store it in _known_regs but instead in _call_stack.
        self._known_regs = {}  # type: Dict[str, Dict[int, Optional[int]]]

        # Set x0 (the zeros register)
        self._known_regs['gpr'] = {0: 0}

        # Registers that must be kept constant. This is used for things like
        # loop bodies, where we want to allow some registers to have known
        # values (so we can use them as e.g. base addresses) and need to make
        # sure not to clobber them.
        self._const_regs = {}  # type: Dict[str, Set[int]]

        # To allow a caller to set _const_regs and unset again afterwards, we
        # have a "const stack". See push_const and pop_const for usage.
        self._const_stack = []  # type: List[Dict[str, Set[int]]]

        # A call stack, representing the contents of x1. The top of the stack
        # is at the end (position -1), to match Python's list.pop function. A
        # entry of None means an entry with an architectural value, but where
        # we don't actually know what it is (usually a result of some
        # arithmetic operation that got written to x1).
        self.call_stack = CallStack()

        # The loop stack.
        self.loop_stack = LoopStack()

        # Known values for memory, keyed by memory type ('dmem', 'csr', 'wsr').
        csrs = KnownMem(4096)
        wsrs = KnownMem(4096)
        self._known_mem = {
            'dmem': KnownMem(dmem_size),
            'csr': csrs,
            'wsr': wsrs
        }

        # Valid CSRs and WSRs
        csrs.touch_addr(0x7c0)      # FG0
        csrs.touch_addr(0x7c1)      # FG1
        csrs.touch_addr(0x7c8)      # FLAGS
        csrs.touch_range(0x7d0, 8)  # MOD0 - MOD7
        csrs.touch_addr(0x7d8)      # RND_PREFETCH
        csrs.touch_addr(0xfc0)      # RND
        csrs.touch_addr(0xfc1)      # URND

        wsrs.touch_addr(0x0)        # MOD
        wsrs.touch_addr(0x1)        # RND
        wsrs.touch_addr(0x2)        # URND
        wsrs.touch_addr(0x3)        # ACC
        wsrs.touch_addr(0x4)        # KEY_S0_L
        wsrs.touch_addr(0x5)        # KEY_S0_H
        wsrs.touch_addr(0x6)        # KEY_S1_L
        wsrs.touch_addr(0x7)        # KEY_S1_H

        # The current PC (the address of the next instruction that needs
        # generating)
        self.pc = 0

    def copy(self) -> 'Model':
        '''Return a deep copy of the model'''
        ret = Model(self.dmem_size, self.initial_fuel)
        ret.pc = self.pc
        ret.fuel = self.fuel
        ret._known_regs = {n: regs.copy()
                           for n, regs in self._known_regs.items()}
        ret._const_regs = {n: regs.copy()
                           for n, regs in self._const_regs.items()}
        for entry in self._const_stack:
            ret._const_stack.append({n: regs.copy()
                                     for n, regs in entry.items()})
        ret.call_stack = self.call_stack.copy()
        ret.loop_stack = self.loop_stack.copy()
        ret._known_mem = {n: mem.copy()
                          for n, mem in self._known_mem.items()}
        return ret

    def _merge_known_regs(self,
                          other: Dict[str, Dict[int, Optional[int]]]) -> None:
        '''Merge known registers from another model'''
        for reg_type in self._known_regs.keys() | other.keys():
            sregs = self._known_regs.get(reg_type)
            oregs = other.get(reg_type)
            if sregs is None:
                # If sregs is None, we have no registers that are known to have
                # architectural values.
                continue
            if oregs is None:
                # If oregs is None, other has no registers with architectural
                # values. Thus the merged model shouldn't have any either.
                del self._known_regs[reg_type]
                continue

            # Both register files have at least some architectural values.
            # Build a new, merged version.
            merged = {}  # type: Dict[int, Optional[int]]
            for reg_name, svalue in sregs.items():
                ovalue = oregs.get(reg_name, 'missing')
                if ovalue == 'missing':
                    # The register is missing from oregs. This means it might
                    # not have an architectural value, so we should skip it
                    # from sregs too.
                    pass
                elif ovalue is None:
                    # The register has an architectural value in other, but not
                    # one we know. Make sure it's unknown here too.
                    merged[reg_name] = None
                else:
                    assert isinstance(ovalue, int)
                    if svalue is None:
                        # The register has an unknown architectural value in
                        # self and a known value in other. So we don't know its
                        # value (but it is still architecturally specified): no
                        # change.
                        merged[reg_name] = None
                    else:
                        # self and other both have a known value for the
                        # register. Do they match? If so, take that value.
                        # Otherwise, make it unknown.
                        merged[reg_name] = None if svalue != ovalue else svalue

            self._known_regs[reg_type] = merged

    def _merge_const_regs(self, other: Dict[str, Set[int]]) -> None:
        '''Merge constant registers from another model'''
        for reg_type in self._const_regs.keys() | other.keys():
            cr = self._const_regs.setdefault(reg_type, set())
            cr |= other.get(reg_type, set())

    def merge(self, other: 'Model') -> None:
        '''Merge in values from another model'''
        assert self.initial_fuel == other.initial_fuel
        self.fuel = min(self.fuel, other.fuel)
        assert self.dmem_size == other.dmem_size

        self._merge_known_regs(other._known_regs)
        self._merge_const_regs(other._const_regs)

        assert self._const_stack == other._const_stack

        self.call_stack.merge(other.call_stack)
        self.loop_stack.merge(other.loop_stack)

        for mem_type, self_mem in self._known_mem.items():
            self_mem.merge(other._known_mem[mem_type])

        assert self.pc == other.pc

    def read_reg(self, reg_type: str, idx: int) -> None:
        '''Update the model for a read of the given register

        This is mostly ignored, but has an effect for x1, which pops from the
        call stack on a read.

        '''
        if reg_type == 'gpr' and idx == 1:
            # We shouldn't ever read from x1 if it is marked constant
            assert not self.is_const('gpr', 1)
            self.call_stack.pop()

    def write_reg(self,
                  reg_type: str,
                  idx: int,
                  value: Optional[int],
                  update: bool) -> None:
        '''Mark a register as having an architectural value

        If value is not None, it is the actual value that the register has.
        Writes to the zeros register x0 are ignored.

        The update flag is normally False. If set, it means that other code has
        already updated the model with a write of a value to the register for
        this instruction, and we should replace that value with the given one,
        which refines the previous value. This is irrelevant for idempotent
        registers, but matters for x1.

        '''
        assert not self.is_const(reg_type, idx)

        if reg_type == 'gpr':
            if idx == 0:
                # Ignore writes to x0
                return

            if idx == 1:
                # Special-case writes to x1
                self.call_stack.write(value, update)
                return

        self._known_regs.setdefault(reg_type, {})[idx] = value

    def get_reg(self, reg_type: str, idx: int) -> Optional[int]:
        '''Get a register value, if known.'''
        if reg_type == 'gpr' and idx == 1:
            return self.call_stack.peek()

        return self._known_regs.setdefault(reg_type, {}).get(idx)

    def touch_mem(self, mem_type: str, base: int, width: int) -> None:
        '''Mark {base .. base+width} as known for given memory type'''
        assert mem_type in self._known_mem
        self._known_mem[mem_type].touch_range(base, width)

    def pick_operand_value(self,
                           op_type: OperandType,
                           weights: Optional[WDict] = None) -> Optional[int]:
        '''Pick a random value for an operand

        The result will always be non-negative: if the operand is a signed
        immediate, this is encoded as 2s complement.

        If op_type is a RegOperandType, the weights argument will be used to
        bias towards particular values. Registers that don't appear in the
        dictionary get a default weight of 1.

        '''
        if isinstance(op_type, RegOperandType):
            return self._pick_reg_operand_value(op_type, weights)
        else:
            assert weights is None
            if isinstance(op_type, ImmOperandType):
                return self._pick_imm_operand_value(op_type)
            elif isinstance(op_type, EnumOperandType):
                return random.randrange(0, len(op_type.items))
            if isinstance(op_type, OptionOperandType):
                return random.randint(0, 1)

            assert 0

    def _pick_reg_operand_value(self,
                                op_type: RegOperandType,
                                weights: Optional[WDict]) -> Optional[int]:
        '''Pick a random value for a register operand

        Returns None if there's no valid value possible.

        '''

        # A register can be used if all of the following hold:
        #
        #   - If the register is used as a source, it has an architecturally
        #     defined value (maybe not known by us, but at least defined).
        #
        #   - If the register is used as a destination, it must not be const.
        #
        #   - For x1 used as a source, the call stack must not be empty and x1
        #     must not be marked constant (since the read will pop from the
        #     call stack).
        #
        #   - For x1 used as a destination, the call stack must not be full and
        #     x1 must not be marked constant.

        is_src = op_type.is_src()
        is_dst = op_type.is_dest()

        assert op_type.width is not None

        reg_set = set(self._known_regs.get(op_type.reg_type, {}).keys()
                      if is_src else range(1 << op_type.width))
        if is_dst:
            reg_set -= self._const_regs.get(op_type.reg_type, set())

        # Special handling for x1
        #
        # Note that this won't allow us to generate things like add x1, x1, x1
        # when the stack is full, because we only do one operand at a time.
        if op_type.reg_type == 'gpr':
            can_use_x1 = not self.is_const('gpr', 1)
            if is_src and self.call_stack.empty():
                can_use_x1 = False
            if is_dst and self.call_stack.full():
                can_use_x1 = False

            # Since x1 isn't tracked in known_regs, we add it here if wanted
            # (to handle the src case) and remove it here if not wanted (to
            # handle the non-src case).
            if can_use_x1:
                reg_set.add(1)
            else:
                reg_set.discard(1)

        if not reg_set:
            return None

        if weights is None:
            if op_type.reg_type == 'gpr' and is_dst and not is_src:
                # Destination registers without a specific set of weights get a
                # default that makes x1 more likely. The idea is that we'll be
                # more likely to fill the call stack this way.
                weights = {1: 8}

        if weights is None:
            return random.choice(list(reg_set))

        regs = []
        reg_weights = []
        for reg in reg_set:
            weight = weights.get(reg, 1)
            assert weight >= 0
            if weight > 0:
                regs.append(reg)
                reg_weights.append(weight)

        if not regs:
            return None

        return random.choices(regs, weights=reg_weights)[0]

    def _pick_imm_operand_value(self,
                                op_type: ImmOperandType) -> Optional[int]:

        op_rng = op_type.get_op_val_range(self.pc)
        if op_rng is None:
            # If we don't know the width, the only immediate that we *know*
            # is going to be valid is 0.
            return 0

        align = 1 << op_type.shift

        lo, hi = op_rng
        sh_lo = (lo + align - 1) // align
        sh_hi = hi // align

        op_val = random.randint(sh_lo, sh_hi) << op_type.shift
        return op_type.op_val_to_enc_val(op_val, self.pc)

    def all_regs_with_known_vals(self) -> Dict[str, List[Tuple[int, int]]]:
        '''Like regs_with_known_vals, but returns all reg types'''
        ret = {}  # type: Dict[str, List[Tuple[int, int]]]
        for rt in self._known_regs.keys():
            kv = self.regs_with_known_vals(rt)
            if kv:
                ret[rt] = kv
        return ret

    def regs_with_known_vals(self, reg_type: str) -> List[Tuple[int, int]]:
        '''Find registers whose values are known and can be read

        Returns a list of pairs (idx, value) where idx is the register index
        and value is its value.

        '''
        known_regs = self._known_regs.get(reg_type)
        if known_regs is None:
            return []

        ret = []
        for reg_idx, reg_val in known_regs.items():
            if reg_val is not None:
                ret.append((reg_idx, reg_val))

        # Handle x1, which has a known value iff the top of the call stack is
        # not None and can be read iff it isn't marked constant.
        if reg_type == 'gpr':
            assert 1 not in known_regs
            if not self.call_stack.empty():
                x1 = self.call_stack.peek()
                if x1 is not None:
                    if not self.is_const('gpr', 1):
                        ret.append((1, x1))

        return ret

    def regs_with_architectural_vals(self, reg_type: str) -> List[int]:
        '''List registers that have an architectural value and can be read'''
        known_regs = self._known_regs.setdefault(reg_type, {})
        arch_regs = list(known_regs.keys())

        # Handle x1, which has an architectural (and known) value iff the call
        # stack is not empty.
        if reg_type == 'gpr':
            assert 1 not in arch_regs
            if not self.call_stack.empty():
                if not self.is_const('gpr', 1):
                    arch_regs.append(1)

        return arch_regs

    def push_const(self) -> int:
        '''Snapshot the current _const_regs state and return a token

        This token should be passed to pop_const (to catch errors from
        unbalanced push/pop pairs)

        '''
        snapshot = {n: regs.copy() for n, regs in self._const_regs.items()}
        self._const_stack.append(snapshot)
        return len(self._const_stack)

    def pop_const(self, token: int) -> None:
        '''Pop an entry from the _const_regs snapshot stack'''
        assert token >= 1
        assert len(self._const_stack) == token
        self._const_regs = self._const_stack.pop()

    def mark_const(self, reg_type: str, reg_idx: int) -> None:
        '''Mark a register as constant

        The model will no longer pick it as a destination operand or allow it
        to be changed.

        '''
        # Marking x0 as constant has no effect (since it is a real constant
        # register)
        if reg_idx == 0 and reg_type == 'gpr':
            return

        self._const_regs.setdefault(reg_type, set()).add(reg_idx)

    def is_const(self, reg_type: str, reg_idx: int) -> bool:
        '''Return true if this register is marked as constant'''
        cr = self._const_regs.get(reg_type)
        if cr is None:
            return False
        return reg_idx in cr

    def forget_value(self, reg_type: str, reg_idx: int) -> None:
        '''If the given register has a known value, forget it.'''
        if reg_type == 'gpr':
            # We always know the value of x0
            if reg_idx == 0:
                return

            # x1 (the call stack) has different handling
            if reg_idx == 1:
                self.call_stack.forget_value()
                return

        # Set the value in known_regs to None, but only if the register already
        # has an architectural value.
        kr = self._known_regs.setdefault(reg_type, {})
        if reg_idx in kr:
            kr[reg_idx] = None

    def pick_lsu_target(self,
                        mem_type: str,
                        loads_value: bool,
                        known_regs: Dict[str, List[Tuple[int, int]]],
                        imm_rng: Tuple[int, int],
                        imm_shift: int,
                        byte_width: int) -> Optional[Tuple[int,
                                                           int,
                                                           Dict[str, int]]]:
        '''Try to pick an address for a naturally-aligned LSU operation.

        mem_type is the type of memory (which must a key of self._known_mem).
        If loads_value, this address needs to have an architecturally defined
        value.

        known_regs is a map from operand name to a list of pairs (idx, value)
        with index and known value for this register operand. Any immediate
        operand will have a value in the range imm_rng (including endpoints)
        and a shift of imm_shift. byte_width is the number of contiguous
        addresses that the LSU operation touches.

        Returns None if we can't find an address. Otherwise, returns a tuple
        (addr, imm_val, reg_vals) where addr is the target address, imm_val is
        the value of any immediate operand and reg_vals is a map from operand
        name to the index picked for that register operand.

        '''
        assert mem_type in self._known_mem
        assert imm_rng[0] <= imm_rng[1]
        assert 0 <= imm_shift

        # A "general" solution to this needs constraint solving, but we expect
        # imm_rng to cover most of the address space most of the time. So we'll
        # do something much simpler: pick a value for each register, then pick
        # a target address that can be reached from the "sum so far" plus the
        # range of the immediate.
        reg_indices = {}
        reg_sum = 0

        # The base address should be aligned to base_align (see the logic in
        # KnownMem.pick_lsu_target), otherwise we'll fail to find anything.
        base_align = math.gcd(byte_width, 1 << imm_shift)

        for name, indices in known_regs.items():
            aligned_regs = [(idx, value)
                            for idx, value in indices
                            if value % base_align == 0]

            # If there are no known aligned indices for this operand, give up
            # now.
            if not aligned_regs:
                return None

            # Otherwise, pick an index and value.
            idx, value = random.choice(aligned_regs)
            reg_sum += value
            reg_indices[name] = idx

        known_mem = self._known_mem[mem_type]
        ret = known_mem.pick_lsu_target(loads_value,
                                        reg_sum,
                                        imm_rng,
                                        1 << imm_shift,
                                        byte_width,
                                        byte_width)

        # If there was no address we could use, give up.
        if ret is None:
            return None

        addr, offset = ret

        return (addr, offset, reg_indices)

    def update_for_lui(self, prog_insn: ProgInsn) -> None:
        '''Update model state after a LUI

        A lui instruction looks like "lui x2, 80000" or similar. This operation
        is easy to understand, so we can actually update the model registers
        appropriately.

        '''
        insn = prog_insn.insn
        op_vals = prog_insn.operands
        assert insn.mnemonic == 'lui'
        assert len(insn.operands) == len(op_vals)

        exp_shape = (len(insn.operands) == 2 and
                     isinstance(insn.operands[0].op_type, RegOperandType) and
                     insn.operands[0].op_type.reg_type == 'gpr' and
                     insn.operands[0].op_type.is_dest() and
                     isinstance(insn.operands[1].op_type, ImmOperandType) and
                     not insn.operands[1].op_type.signed)
        if not exp_shape:
            raise RuntimeError('LUI instruction read from insns.yml is '
                               'not the shape expected by '
                               'Model.update_for_lui.')

        self._generic_update_for_insn(prog_insn)

        assert op_vals[1] >= 0
        self.write_reg('gpr', op_vals[0], op_vals[1] << 12, True)

    def update_for_addi(self, prog_insn: ProgInsn) -> None:
        '''Update model state after an ADDI

        If the source register happens to have a known value, we can do the
        addition and store the known result.

        '''
        insn = prog_insn.insn
        op_vals = prog_insn.operands
        assert insn.mnemonic == 'addi'
        assert len(insn.operands) == len(op_vals)

        exp_shape = (len(insn.operands) == 3 and
                     isinstance(insn.operands[0].op_type, RegOperandType) and
                     insn.operands[0].op_type.reg_type == 'gpr' and
                     insn.operands[0].op_type.is_dest() and
                     isinstance(insn.operands[1].op_type, RegOperandType) and
                     insn.operands[1].op_type.reg_type == 'gpr' and
                     not insn.operands[1].op_type.is_dest() and
                     isinstance(insn.operands[2].op_type, ImmOperandType) and
                     insn.operands[2].op_type.signed)
        if not exp_shape:
            raise RuntimeError('ADDI instruction read from insns.yml is '
                               'not the shape expected by '
                               'Model.update_for_addi.')

        src_val = self.get_reg('gpr', op_vals[1])
        if src_val is None:
            result = None
        else:
            # op_vals[2] is the immediate, but is already "encoded" as an
            # unsigned value. Turn it back into the signed operand that
            # actually gets added.
            imm_op = insn.operands[2]
            imm_val = imm_op.op_type.enc_val_to_op_val(op_vals[2], self.pc)
            assert imm_val is not None
            result = (src_val + imm_val) & ((1 << 32) - 1)

        self._generic_update_for_insn(prog_insn)

        self.write_reg('gpr', op_vals[0], result, True)

    def _inc_gpr(self,
                 gpr: int,
                 gpr_val: Optional[int],
                 delta: int) -> None:
        '''Mark gpr as having a value and increment it if known

        This passes update=False to self.write_reg: it should be used for
        registers that haven't already been marked as updated by the
        instruction.

        '''
        mask = (1 << 32) - 1
        new_val = (gpr_val + delta) & mask if gpr_val is not None else None
        self.write_reg('gpr', gpr, new_val, False)

    def update_for_bnlid(self, prog_insn: ProgInsn) -> None:
        '''Update model state after an BN.LID

        We need this special case code because of the indirect access to the
        wide-side register file.

        '''
        insn = prog_insn.insn
        op_vals = prog_insn.operands
        assert insn.mnemonic == 'bn.lid'
        assert len(insn.operands) == len(op_vals)

        grd_op, grs1_op, offset_op, grs1_inc_op, grd_inc_op = insn.operands
        exp_shape = (
            # grd
            isinstance(grd_op.op_type, RegOperandType) and
            grd_op.op_type.reg_type == 'gpr' and
            not grd_op.op_type.is_dest() and
            # grs1
            isinstance(grs1_op.op_type, RegOperandType) and
            grs1_op.op_type.reg_type == 'gpr' and
            not grs1_op.op_type.is_dest() and
            # offset
            isinstance(offset_op.op_type, ImmOperandType) and
            offset_op.op_type.signed and
            # grs1_inc
            isinstance(grs1_inc_op.op_type, OptionOperandType) and
            # grd_inc
            isinstance(grd_inc_op.op_type, OptionOperandType)
        )
        if not exp_shape:
            raise RuntimeError('Unexpected shape for bn.lid')

        grd, grs1, _offset, grs1_inc, grd_inc = op_vals
        grd_val = self.get_reg('gpr', grd)
        grs1_val = self.get_reg('gpr', grs1)

        self._generic_update_for_insn(prog_insn)

        if grd_val is not None:
            self.write_reg('wdr', grd_val & 31, None, False)

        if grs1_inc:
            self._inc_gpr(grs1, grs1_val, 32)
        elif grd_inc:
            self._inc_gpr(grd, grd_val, 1)

    def update_for_bnsid(self, prog_insn: ProgInsn) -> None:
        '''Update model state after an BN.SID'''
        insn = prog_insn.insn
        op_vals = prog_insn.operands
        assert insn.mnemonic == 'bn.sid'
        assert len(insn.operands) == len(op_vals)

        grs1_op, grs2_op, offset_op, grs1_inc_op, grs2_inc_op = insn.operands
        exp_shape = (
            # grs1
            isinstance(grs1_op.op_type, RegOperandType) and
            grs1_op.op_type.reg_type == 'gpr' and
            not grs1_op.op_type.is_dest() and
            # grs2
            isinstance(grs2_op.op_type, RegOperandType) and
            grs2_op.op_type.reg_type == 'gpr' and
            not grs2_op.op_type.is_dest() and
            # offset
            isinstance(offset_op.op_type, ImmOperandType) and
            offset_op.op_type.signed and
            # grs1_inc
            isinstance(grs1_inc_op.op_type, OptionOperandType) and
            # grs2_inc
            isinstance(grs2_inc_op.op_type, OptionOperandType)
        )
        if not exp_shape:
            raise RuntimeError('Unexpected shape for bn.sid')

        grs1, grs2, _offset, grs1_inc, grs2_inc = op_vals
        grs1_val = self.get_reg('gpr', grs1)
        grs2_val = self.get_reg('gpr', grs2)

        self._generic_update_for_insn(prog_insn)

        if grs1_inc:
            self._inc_gpr(grs1, grs1_val, 32)
        elif grs2_inc:
            self._inc_gpr(grs2, grs2_val, 1)

    def update_for_bnmovr(self, prog_insn: ProgInsn) -> None:
        '''Update model state after an BN.MOVR'''
        insn = prog_insn.insn
        op_vals = prog_insn.operands
        assert insn.mnemonic == 'bn.movr'
        assert len(insn.operands) == len(op_vals)

        grd_op, grs_op, grd_inc_op, grs_inc_op = insn.operands
        exp_shape = (
            # grd
            isinstance(grd_op.op_type, RegOperandType) and
            grd_op.op_type.reg_type == 'gpr' and
            not grd_op.op_type.is_dest() and
            # grs
            isinstance(grs_op.op_type, RegOperandType) and
            grs_op.op_type.reg_type == 'gpr' and
            not grs_op.op_type.is_dest() and
            # grd_inc
            isinstance(grd_inc_op.op_type, OptionOperandType) and
            # grs_inc
            isinstance(grs_inc_op.op_type, OptionOperandType)
        )
        if not exp_shape:
            raise RuntimeError('Unexpected shape for bn.movr')

        grd, grs, grd_inc, grs_inc = op_vals
        grd_val = self.get_reg('gpr', grd)
        grs_val = self.get_reg('gpr', grs)

        self._generic_update_for_insn(prog_insn)

        if grd_val is not None:
            self.write_reg('wdr', grd_val & 31, None, False)

        if grd_inc:
            self._inc_gpr(grd, grd_val, 1)
        elif grs_inc:
            self._inc_gpr(grs, grs_val, 1)

    def update_for_bnxor(self, prog_insn: ProgInsn) -> None:
        '''Update model state after an BN.XOR

        If the source register happens to have a known value, we can do the
        addition and store the known result.

        '''
        insn = prog_insn.insn
        op_vals = prog_insn.operands
        assert insn.mnemonic == 'bn.xor'
        assert len(insn.operands) == len(op_vals)

        exp_shape = (isinstance(insn.operands[0].op_type, RegOperandType) and
                     insn.operands[0].op_type.reg_type == 'wdr' and
                     insn.operands[0].op_type.is_dest() and
                     isinstance(insn.operands[1].op_type, RegOperandType) and
                     insn.operands[1].op_type.reg_type == 'wdr' and
                     not insn.operands[1].op_type.is_dest() and
                     isinstance(insn.operands[2].op_type, RegOperandType) and
                     insn.operands[2].op_type.reg_type == 'wdr' and
                     not insn.operands[2].op_type.is_dest() and
                     isinstance(insn.operands[4].op_type, ImmOperandType))
        if not exp_shape:
            raise RuntimeError('BN.XOR instruction read from insns.yml is '
                               'not the shape expected by '
                               'Model.update_for_bnxor.')

        wrs1_val = self.get_reg('wdr', op_vals[1])
        wrs2_val = self.get_reg('wdr', op_vals[2])

        result = None

        # It is known that both sources are same, result of XOR is always 0
        if (op_vals[1] == op_vals[2]) and (op_vals[4] == 0):
            result = 0
        elif wrs1_val is None or wrs2_val is None:
            pass
        else:
            if op_vals[3]:
                src2_val = wrs2_val >> op_vals[4]
                result = (wrs1_val ^ src2_val)
            else:
                src2_val = wrs2_val << op_vals[4]
                result = (wrs1_val ^ src2_val)

        self._generic_update_for_insn(prog_insn)

        self.write_reg('wdr', op_vals[0], result, True)

    def update_for_bnnot(self, prog_insn: ProgInsn) -> None:
        '''Update model state after an BN.NOT

        If the source register happens to have a known value, we can do the
        addition and store the known result.

        '''
        insn = prog_insn.insn
        op_vals = prog_insn.operands
        assert insn.mnemonic == 'bn.not'
        assert len(insn.operands) == len(op_vals)

        exp_shape = (isinstance(insn.operands[0].op_type, RegOperandType) and
                     insn.operands[0].op_type.reg_type == 'wdr' and
                     insn.operands[0].op_type.is_dest() and
                     isinstance(insn.operands[1].op_type, RegOperandType) and
                     insn.operands[1].op_type.reg_type == 'wdr' and
                     not insn.operands[1].op_type.is_dest() and
                     isinstance(insn.operands[2].op_type, EnumOperandType) and
                     isinstance(insn.operands[3].op_type, ImmOperandType))
        if not exp_shape:
            raise RuntimeError('BN.NOT instruction read from insns.yml is '
                               'not the shape expected by '
                               'Model.update_for_bnnot.')

        wrs_val = self.get_reg('wdr', op_vals[1])

        result = None
        if wrs_val is not None:
            if op_vals[2]:
                src_val = wrs_val >> op_vals[4]
            else:
                src_val = wrs_val << op_vals[4]
            result = (src_val ^ ((1 << 256) - 1))

        self._generic_update_for_insn(prog_insn)

        self.write_reg('wdr', op_vals[0], result, True)

    def _generic_update_for_insn(self, prog_insn: ProgInsn) -> None:
        '''Update registers and memory for prog_insn

        Apply side-effecting reads (relevant for x1) then mark any destination
        operand as having an architectural value. Finally, apply any memory
        changes.

        This is called by update_for_insn, either by the specialized updater if
        there is one or on its own if there's none.

        '''
        seen_writes = []  # type: List[Tuple[str, int]]
        seen_reads = set()  # type: Set[Tuple[str, int]]
        insn = prog_insn.insn
        assert len(insn.operands) == len(prog_insn.operands)
        for operand, op_val in zip(insn.operands, prog_insn.operands):
            op_type = operand.op_type
            if isinstance(op_type, RegOperandType):
                if op_type.is_dest():
                    seen_writes.append((op_type.reg_type, op_val))
                else:
                    seen_reads.add((op_type.reg_type, op_val))
        for op_reg_type, op_val in seen_reads:
            self.read_reg(op_reg_type, op_val)
        for reg_type, op_val in seen_writes:
            self.write_reg(reg_type, op_val, None, False)

        # If this is an LSU operation, we've either loaded a value (in which
        # case, the memory hopefully had a value already) or we've stored
        # something. In either case, we mark the memory as having a value now.
        if prog_insn.lsu_info is not None:
            assert insn.lsu is not None
            mem_type, addr = prog_insn.lsu_info
            self.touch_mem(mem_type, addr, insn.lsu.idx_width)

    def consume_fuel(self) -> None:
        '''Consume one item of fuel'''
        assert self.fuel > 0
        self.fuel -= 1

    def update_for_insn(self, prog_insn: ProgInsn) -> None:
        # If this is a sufficiently simple operation that we understand the
        # result, or a complicated instruction where we have to do something
        # clever, actually set the destination register with a value.
        updaters = {
            'lui': self.update_for_lui,
            'addi': self.update_for_addi,
            'bn.lid': self.update_for_bnlid,
            'bn.sid': self.update_for_bnsid,
            'bn.movr': self.update_for_bnmovr,
            'bn.xor': self.update_for_bnxor,
            'bn.not': self.update_for_bnnot
        }
        updater = updaters.get(prog_insn.insn.mnemonic)
        if updater is not None:
            updater(prog_insn)
        else:
            self._generic_update_for_insn(prog_insn)

        self.consume_fuel()

    def pick_bad_addr(self, mem_type: str) -> Optional[int]:
        return self._known_mem[mem_type].pick_bad_addr()
