# Third-party notices

Quartzite's own code is under the MIT license (see `LICENSE`). It does not bundle
third-party code. The optional bitstream toolchain is downloaded and built on your machine
by `toolchain/build_toolchain.sh`; each project stays under its own license:

| Project | Used for | License |
|---|---|---|
| [Mistral](https://github.com/Ravenslofty/mistral) | Cyclone V bitstream database and `mistral-cv` | BSD-3-Clause |
| [nextpnr](https://github.com/YosysHQ/nextpnr) | Place and route (`nextpnr-mistral`) | ISC |
| [Yosys](https://github.com/YosysHQ/yosys) | Synthesis (installed with Homebrew) | ISC |

`toolchain/patches/` holds small build fixes for macOS that apply to Mistral and nextpnr.
Those patches modify files of those projects and are offered under the same license as the
file they patch.

## Data and formats

- DE10-Standard pin locations come from Terasic's published board files (factual data).
- Primitive symbol geometry and the `.bdf`, `.qsf`, `.vwf` and `.sof` layouts were worked
  out from files written by Quartus, for interoperability. No Intel or Altera software,
  libraries or documentation are included.
- Quartus, Quartus Prime, Cyclone and Intel are trademarks of Intel Corporation or its
  subsidiaries. Altera is a trademark of Altera Corporation. Terasic and DE10-Standard
  belong to Terasic Inc. Quartzite is not affiliated with or endorsed by any of them.
