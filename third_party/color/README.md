# Default CMYK profile

`SWOP_TR005_coated_5.icc` ("SWOP TR005 Coated"): U.S. grade 5 coated paper, sheetfed offset and gravure. It is the
Linux stand-in for macOS's Generic CMYK Profile, which upstream proofs and exports through when the user has chosen
none. Apple's profile cannot be redistributed. The app installs this one as `Generic CMYK Profile.icc` in its
`CMYK Profiles` folder on first run (`ColorSyncGenericProfiles.installBundledDefault`).

- Source: colord 1.4.8 (`data/profiles/SWOP_TR005_coated_5.iccprofile.xml`), as built in Debian's
  `colord-data_1.4.8-3_all.deb` (`/usr/share/color/icc/colord/SWOP_TR005_coated_5.icc`).
- SHA-256: `83cecb046506bb3ad976cd549ecc3b90598c0f15b7d3e8d2a4c987b3c723889a`
- Licence: CC0-1.0 (© 2012 Richard Hughes).
- Characterization data: ANSI CGATS/SWOP TR 005-2007, © 2007 NPES The Association for Suppliers of Printing,
  Publishing and Converting Technologies. "Profiles, or other derivative work, based on these data may be distributed
  with no further permissions from CGATS. However, this Technical Report must be identified as the source of the
  characterization data."
