// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
{
  name:               "${module_instance_name}",
  human_name:         "Pulse Width Modulator",
  one_line_desc:      "Transmission of pulse-width modulated output signals with adjustable duty cycle",
  one_paragraph_desc: '''
  Pulse Width Modulator creates pulse-width modulated (PWM) signals with adjustable duty cycle.
  It is suitable for general-purpose use, but primarily designed for control of LEDs.
  All outputs are programmable with frequency, phase, and duty cycle.
  '''
  // Unique comportable IP identifier defined under KNOWN_CIP_IDS in the regtool.
  cip_id:             "19",
  design_spec:        "../doc",
  dv_doc:             "../doc/dv",
  hw_checklist:       "../doc/checklist",
  sw_checklist:       "/sw/device/lib/dif/dif_pwm",
  revisions: [
    {
      version:            "1.0.0",
      life_stage:         "L1",
      design_stage:       "D2S",
      verification_stage: "V2S",
      dif_stage:          "S2",
      notes:              ""
    }
  ]
  clocking: [
    {clock: "clk_i", reset: "rst_ni", primary: true},
    {clock: "clk_core_i", reset: "rst_core_ni"}
  ]
  bus_interfaces: [
    { protocol: "tlul", direction: "device", racl_support: true }
  ],
  regwidth: "32",
  param_list: [
    { name: "NOutputs",
      desc: "Number of PWM outputs",
      type: "int",
      default: "${nr_output_channels}",
    }
  ]
  available_output_list: [
    { name:  "pwm"
      desc:  '''Pulse output.  Note that though this output is always enabled, there is a formal
                set of enable pins (pwm_en_o) which are required for top-level integration of
                comportable IPs.'''
      width: "${nr_output_channels}"
    }
  ]
  alert_list: [
    { name: "fatal_fault",
      desc: '''
      This fatal alert is triggered when a fatal TL-UL bus integrity fault is detected.
      '''
    }
  ],
  features: [
    { name: "PWM.DUTYCYCLE",
      desc: ''' The duty cycle of the generated pulse can be changed.
                '''
    },
    { name: "PWM.BLINK",
      desc: ''' Duty cycle switches between one programmable value and another.
                '''
    },
    { name: "PWM.HEARTBEAT",
      desc: ''' Duty cycle linearly increases from one programmable value to another.
                '''
    },
    { name: "PWM.POLARITY",
      desc: ''' PWM is active high by default, but this can be changed.
                '''
    },
    { name: "PWM.CLOCKDIVIDER",
      desc: ''' The duty cycles are set with counters, and a clock divider can be set to adjust the clock for all of these counters.
                '''
    },
    { name: "PWM.PHASEDELAY",
      desc: ''' Different PWM signals can be offset in phase.
                '''
    }
  ],
  countermeasures: [
    { name: "BUS.INTEGRITY",
      desc: "End-to-end bus integrity scheme."
    }
  ]
  inter_signal_list: [
    { struct:  "racl_policy_vec",
      type:    "uni",
      name:    "racl_policies",
      act:     "rcv",
      package: "top_racl_pkg",
      desc:    '''
        Incoming RACL policy vector from a racl_ctrl instance.
        The policy selection vector (parameter) selects the policy for each register.
      '''
    }
    { struct:  "racl_error_log",
      type:    "uni",
      name:    "racl_error",
      act:     "req",
      width:   "1"
      package: "top_racl_pkg",
      desc:    '''
        RACL error log information of this module.
      '''
    }
  ],
  registers: [
    { name: "REGWEN",
      desc: "Register write enable for all control registers",
      swaccess: "rw0c",
      hwaccess: "none",
      fields: [
        { bits: "0",
          desc: ''' When true, all writable registers can be modified.
                    When false, they become read-only. Defaults true, write
                    zero to clear. This can be cleared after initial
                    configuration at boot in order to lock in the supplied
                    register settings.'''
          resval: 1
        }
      ]
    }
    { name: "CFG",
      desc: "Configuration register",
      swaccess: "rw",
      async: "clk_core_i",
      hwqe: "true",
      regwen: "REGWEN",
      fields: [
        { bits: "31",
          name: "CNTR_EN",
          desc: '''Assert this bit to enable the PWM phase counter.
                   Clearing this bit disables and resets the phase counter.'''
          resval: "0x0"
        },
        { bits: "30:27",
          name: "DC_RESN"
          desc: '''Phase Resolution (logarithmic). All duty-cycle and phase
                   shift registers represent fractional PWM cycles, expressed in
                   units of 2^-16 PWM cycles. Each PWM cycle is divided
                   into 2^(DC_RESN+1) time slices, and thus only the (DC_RESN+1)
                   most significant bits of each phase or duty cycle register
                   are relevant.'''
          resval: 7
        },
        { bits: "26:0",
          name: "CLK_DIV",
          desc: '''Sets the period of each PWM beat to be (CLK_DIV+1)
                   input clock periods.  Since PWM pulses are generated once
                   every 2^(DC_RESN+1) beats, the period between output
                   pulses is 2^(DC_RESN+1)*(CLK_DIV+1) times longer than the
                   input clock period.'''
          resval: "0x00008000"
        }
      ]
    },
    { multireg: { name: "PWM_EN",
        desc: "Enable PWM operation for each channel",
        count: "NOutputs",
        swaccess: "rw",
        cname: "pwm_en",
        compact: "1",
        async: "clk_core_i",
        hwqe: "true",
        regwen: "REGWEN",
        fields: [
          { bits: "0",
            name: "EN",
            desc: '''Write 1 to this bit to enable PWM pulses on the
                     corresponding channel.''',
            resval: "0"
          }
        ]
      }
    },
    { multireg: { name: "INVERT",
        desc: "Invert the PWM output for each channel",
        count: "NOutputs",
        swaccess: "rw",
        cname: "pwm_invert",
        compact: "1",
        async: "clk_core_i",
        hwqe: "true",
        regwen: "REGWEN",
        fields: [
          { bits: "0",
            name: "INVERT",
            desc: '''Write 1 to this bit to invert the output for each channel,
                     so that the corresponding output is active-low.''',
            resval: "0"
          }
        ]
      }
    },
    { multireg: { name: "PWM_PARAM",
        desc: "Basic PWM Channel Parameters",
        count: "NOutputs"
        swaccess: "rw",
        cname: "pwm_params",
        async: "clk_core_i",
        hwqe: "true",
        regwen: "REGWEN",
        fields: [
          { bits: "31",
            name: "BLINK_EN",
            desc: '''Enables blink (or heartbeat).  If cleared, the output duty
                     cycle will remain constant at DUTY_CYCLE.A. Enabling this
                     bit  causes the PWM duty cycle to alternate between
                     DUTY_CYCLE.A and DUTY_CYCLE.B'''
            resval: 0
          },
          { bits: "30",
            name: "HTBT_EN",
            desc: '''Modulates blink behavior to create a heartbeat effect. When
                     HTBT_EN is set, the duty cycle increases (or decreases)
                     linearly from DUTY_CYCLE.A to DUTY_CYCLE.B and back, in
                     steps of (BLINK_PARAM.Y+1), with an increment (decrement)
                     once every (BLINK_PARAM.X+1) PWM cycles.

                     When HTBT_EN is cleared, the standard blink behavior applies,
                     meaning that the output duty cycle alternates between DUTY_CYCLE.A for
                     (BLINK_PARAM.X+1) pulses and DUTY_CYCLE.B for
                     (BLINK_PARAM.Y+1) pulses.'''
            resval: 0
          },
          { bits: "15:0",
            name: "PHASE_DELAY",
            desc: '''Phase delay of the PWM leading edge, in units of 2^(-16) PWM
                     cycles. The leading edge will be the rising edge of the output
                     signal unless the corresponding INVERT bit is set.''',
            resval: "0x0000"
          }
        ]
      }
    },
    { multireg: { name: "DUTY_CYCLE",
        desc:'''Controls the duty_cycle of each channel.''',
        count: "NOutputs"
        swaccess: "rw",
        cname: "duty_cycle",
        async: "clk_core_i",
        hwqe: "true",
        regwen: "REGWEN",
        fields: [
          { bits: "31:16",
            name: "B",
            desc: '''The target duty cycle for PWM output, in units
                     of 2^(-16)ths of a pulse cycle. The actual precision is
                     however limited to the (DC_RESN+1) most significant bits.
                     This setting only applies when blinking, and determines
                     the target duty cycle.'''
            resval: "0x7fff"
          }
          { bits: "15:0",
            name: "A",
            desc: '''The initial duty cycle for PWM output, in units
                     of 2^(-16)ths of a pulse cycle. The actual precision is
                     however limited to the (DC_RESN+1) most significant bits.
                     This setting applies continuously when not blinking
                     and determines the initial duty cycle when blinking.'''
            resval: "0x7fff"
          }
        ]
      }
    },
    { multireg: { name: "BLINK_PARAM",
        desc: "Hardware controlled blink/heartbeat parameters.",
        count: "NOutputs"
        swaccess: "rw",
        cname: "blink_param",
        async: "clk_core_i",
        hwqe: "true",
        regwen: "REGWEN",
        fields: [
          { bits: "15:0",
            name: "X",
            desc: '''This blink-rate timing parameter has two different
                     interpretations depending on whether or not the heartbeat
                     feature is enabled. If heartbeat is disabled, a blinking
                     PWM will pulse at duty cycle A for (X+1) pulse cycles before
                     switching to duty cycle B. If heartbeat is enabled
                     the duty cycle will start at duty cycle A, but
                     will be incremented (or decremented) every (X+1) cycles.
                     In heartbeat mode is enabled, the size of each step is
                     controlled by BLINK_PARAM.Y.'''
            resval: "0x00"
          }
          { bits: "31:16",
            name: "Y",
            desc: '''This blink-rate timing parameter has two different
                     interpretations depending on whether or not the heartbeat
                     feature is enabled. If heartbeat is disabled, a blinking
                     PWM will pulse at duty cycle B for (Y+1) pulse cycles
                     before returning to duty cycle A. If heartbeat is enabled
                     the duty cycle will increase (or decrease) by (Y+1) units
                     every time it is incremented (or decremented).'''
            resval: "0x0"
          }
        ]
      }
    }
  ]
}
