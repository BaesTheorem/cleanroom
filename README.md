# Cleanroom

An iPhone app and a Mac command-line tool that take the metadata out of photos
and videos, then check their own result.

Two things set it apart from the scrubbers on the App Store.

It does not re-encode. For JPEG, PNG, HEIC, HEIF, AVIF, MOV and MP4 the
compressed picture or the compressed samples come out byte for byte the same.
Most scrubbers decode the picture and save a new JPEG, which costs quality and
drops HDR.

It does not trust itself. After every scrub a different parser reads the new
file, and a file that fails any check is deleted and never offered for sharing.

## What goes and what stays

Removed:

- Exif, GPS, maker notes, XMP, IPTC and Photoshop blocks
- the thumbnail inside the Exif block (it can show the picture as it was before a crop)
- text comments, content credentials (C2PA), vendor segments
- anything after the end of the picture, except an HDR gain map
- in a movie: every metadata atom, and every track that is not picture, sound or captions (timed metadata, timecode, depth)
- the file name, unless you turn that off. `IMG_4123` tells how many pictures the camera took before this one.

Kept, because the picture renders wrong without it:

- rotation
- the color profile
- the HDR gain map and the two headroom numbers older iPhone pictures need to use it

Pictures in other formats (TIFF, GIF, BMP, RAW) have no byte-level scrubber
here. Those are decoded and encoded again, and the app marks them as rebuilt.

## The checks

Each output goes through three before the app calls it clean.

1. ImageIO (pictures) or AVFoundation (movies) reads the new file. Every field it reports must be on a short allowlist of rendering facts. The scrubber writes with its own byte-level code, so this is a second opinion from code that shares nothing with it.
2. A byte-level walk of the output must find only allowlisted segments, chunks, boxes and tracks.
3. A picture is decoded before and after, and the pixels, the rotation and the color space must match. For a movie, the SHA-256 of every copied track must match the original.

## What the test files turned up

A few of these changed the design.

### An iPhone writes the capture time into a color profile

An HDR photo from an
iPhone 16 Pro carries a second picture, the gain map, and that picture has its
own ICC profile. The creation date in that profile's header is the moment the
photo was taken, to the second. A scrubber that keeps the gain map and only
strips tags leaves it in. Cleanroom zeroes the date and the checksum of any
profile that is not a standard one.

### Standard profiles must stay untouched

The first version zeroed the date in
every profile. ImageIO then stopped recognizing Display P3 and sRGB as the named
color spaces, because it matches them by their exact bytes. Every copy of a
standard profile has the same date, so there is nothing to hide. The rule is now:
if CoreGraphics knows the profile by name, leave it alone.

### Some cameras name their color space only in tags

A Canon file shot in Adobe
RGB had no embedded profile. The decoder worked out the color space from the
Exif block and the maker note, so removing those changed the colors. When the
decoder assigns a profile that the file does not carry, Cleanroom embeds that
profile, so the colors no longer depend on the tags.

### Apple's JPEG encoder adds a segment of its own

Files that go through the
rebuild path came back from ImageIO with an `AROT` segment. The rebuild path
now ends with the same byte-level pass as everything else.

### PNG rotation is fragile

ImageIO honors the Exif chunk of a PNG only when
it comes before the pixel data, and for a file that has both XMP and Exif chunks
the decoded rotation depended on whether the properties had been read first. The
pixel check reads the properties first, so the comparison is stable.

## How it was tested

`bin/check-corpus` scrubs every file in a folder and then asks tools that share
no code with the scrubber:

- ExifTool reads the output. Every tag must be on an allowlist, and no profile date may equal a date from the original.
- A residue search cuts the original Exif and XMP blocks into 16-byte pieces and looks for each piece in the output, along with the raw GPS coordinate bytes and planted `CANARY` strings.
- ffmpeg decodes the picture before and after, or copies the movie packets, and the hashes must match. HEIC uses a full-size HDR decode.
- `exiftool -validate` must report no error.

Result on 121 files (ExifTool 13.55, ffmpeg 9.0, macOS 26.3): 121 clean, 110
with no re-encode, 11 rebuilt (9 TIFF, 1 GIF, 1 truncated JPEG).

- 104 public files from [ianare/exif-samples](https://github.com/ianare/exif-samples): cameras and phones from 19 makers, GPS, XMP, all eight orientations, HEIC from phones, broken files
- 13 synthetic files with planted metadata in every block ExifTool can write
- 4 private iPhone files, including two HDR photos from an iPhone 16 Pro

The checker fails unscrubbed files, which was confirmed by pointing it at the
originals.

Not tested yet: iPhone video with timed metadata tracks, ProRAW, spatial
photos, Android Ultra HDR, and memory use of the share extension on 48 MP
files. The code handles the first two by design, but no real file of that kind
has been through the corpus check.

## Limits

- It does not change what the picture shows. A street sign, a face or a reflection is still there.
- Camera sensor noise can identify a camera, and no metadata tool removes it.
- Traces an encoder leaves in the compressed data stay: quantization tables, the vendor code in a movie's sample description, and text an encoder writes into the video stream itself.
- A Live Photo comes out as a still.
- In a JPEG, only a gain map that carries the ISO 21496-1 segment or Apple's gain map type is kept. An older Android gain map described only by XMP is dropped, and the picture renders without HDR.
- In a HEIC, the thumbnail picture and auxiliary pictures (depth map, portrait matte) stay. Their XMP goes.
- A scrubbed movie carries the time of the scrub in its header.
- The profile of a display (a screenshot from a Mac, for example) keeps its name, which can be the model of the monitor. Its date and serial number go.

## Use

### Mac

```sh
bin/scrub clean ~/Desktop/photo.jpg -o ~/Desktop/clean
bin/scrub inspect photo.heic      # what Apple's parsers read
bin/scrub plan photo.heic         # what a scrub would do to each part
```

### iPhone

Needs Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
cd ios
cp Config/Signing.xcconfig.example Config/Signing.xcconfig   # put in your team id
xcodegen generate
open Cleanroom.xcodeproj
```

The app picks files with the system photo picker, so it never asks for access
to the library. It also installs a share-sheet action: in Photos or Files, tap
Share, then Cleanroom, and it scrubs what you sent and offers the clean copies.
Saving to Photos asks for add-only access.

The app has no networking code. After you use it, iOS Settings > Privacy &
Security > App Privacy Report lists no network activity for it.

### Run the checks

```sh
brew install exiftool ffmpeg
bin/fetch-corpus            # public samples and synthetic files, into corpus/
cd ScrubKit && swift build && swift test && cd ..
bin/check-corpus
```

## Layout

- `ScrubKit/` is the engine, a Swift package with no dependencies. `JPEG.swift`, `PNG.swift` and `HEIF.swift` are the byte-level scrubbers, `Movie.swift` copies samples, `ICC.swift` handles color profiles, `Verify.swift` holds the checks.
- `ios/` is the app and its share extension. The look is in [DESIGN.md](DESIGN.md).
- `bin/` holds `scrub` (the Mac command, built on first use) and the corpus scripts.

## Credits

- [ExifTool](https://exiftool.org) by Phil Harvey is the reference these results are measured against.
- Test pictures: [ianare/exif-samples](https://github.com/ianare/exif-samples). They are downloaded by `bin/fetch-corpus` and are not in this repo.
- Type: [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) and [Inter](https://github.com/rsms/inter), both under the SIL Open Font License. The license texts sit next to the font files.
- [MetaX](https://github.com/Ckitakishi/MetaX) and [CleanPic](https://github.com/davidbond17/cleanpic) were read before this was written. No code from either is here.

## License

MIT. See [LICENSE](LICENSE).
