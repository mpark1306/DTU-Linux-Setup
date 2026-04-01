#!/usr/bin/env bash
###############################################################################
# DTU Sustain – openSUSE Tumbleweed – Module: Brother P950NW (from source)
# No printer-driver-ptouch package on Tumbleweed — builds from source.
###############################################################################
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"
need_root

banner "Brother P950NW Label Printer (from source)"

PRINTER_NAME="Brother_P950NW"
PRINTER_IP="10.61.1.9"
PPD_NAME="Brother-PT-P950NW-ptouch-pt.ppd"
PPD_DIR="/usr/share/cups/model/ptouch"
BUILD_DIR="/tmp/printer-driver-ptouch"
CUPS_FILTER_DIR="/usr/lib/cups/filter"

echo "[1/7] Installing build dependencies + CUPS..."
zypper --non-interactive install cups gcc cups-devel autoconf automake libtool git-core

echo "[2/7] Enabling CUPS..."
systemctl enable --now cups
systemctl restart cups

echo "[3/7] Cloning ptouch-driver source..."
rm -rf "$BUILD_DIR"
git clone https://github.com/philpem/printer-driver-ptouch.git "$BUILD_DIR"

echo "[4/7] Building rastertoptch filter..."
cd "$BUILD_DIR"
autoreconf -fi
./configure
make 2>/dev/null || true

if [[ ! -f "$BUILD_DIR/rastertoptch" ]]; then
  fail "rastertoptch filter did not compile."
  exit 1
fi

echo "[5/7] Installing filter..."
cp "$BUILD_DIR/rastertoptch" "${CUPS_FILTER_DIR}/"
chmod 755 "${CUPS_FILTER_DIR}/rastertoptch"

echo "[6/7] Installing PPD..."
mkdir -p "$PPD_DIR"
cat > "${PPD_DIR}/${PPD_NAME}" <<'PPD'
*PPD-Adobe: "4.3"
*FormatVersion: "4.3"
*FileVersion: "1.0"
*LanguageVersion: English
*LanguageEncoding: ISOLatin1
*PCFileName: "BrPTP950.ppd"
*Manufacturer: "Brother"
*Product: "(PT-P950NW)"
*ModelName: "Brother PT-P950NW"
*ShortNickName: "Brother PT-P950NW ptouch-pt"
*NickName: "Brother PT-P950NW ptouch-pt"
*PSVersion: "(3010.000) 0"
*LanguageLevel: "3"
*ColorDevice: False
*DefaultColorSpace: Gray
*FileSystem: False
*Throughput: "1"
*LandscapeOrientation: Plus90
*TTRasterizer: Type42
*cupsFilter: "application/vnd.cups-raster 100 rastertoptch"
*cupsModelNumber: 0
*OpenUI *PageSize/Tape Width: PickOne
*OrderDependency: 10 AnySetup *PageSize
*DefaultPageSize: tz-12
*PageSize tz-4/3.5mm:          "<</PageSize[10 283]/ImagingBBox null>>setpagedevice"
*PageSize tz-6/6mm:            "<</PageSize[17 283]/ImagingBBox null>>setpagedevice"
*PageSize tz-9/9mm:            "<</PageSize[26 283]/ImagingBBox null>>setpagedevice"
*PageSize tz-12/12mm:          "<</PageSize[34 283]/ImagingBBox null>>setpagedevice"
*PageSize tz-18/18mm:          "<</PageSize[51 283]/ImagingBBox null>>setpagedevice"
*PageSize tz-24/24mm:          "<</PageSize[68 283]/ImagingBBox null>>setpagedevice"
*PageSize tz-36/36mm:          "<</PageSize[102 283]/ImagingBBox null>>setpagedevice"
*PageSize hs-6/HS 5.8mm:       "<</PageSize[16 283]/ImagingBBox null>>setpagedevice"
*PageSize hs-9/HS 8.8mm:       "<</PageSize[25 283]/ImagingBBox null>>setpagedevice"
*PageSize hs-12/HS 11.7mm:     "<</PageSize[33 283]/ImagingBBox null>>setpagedevice"
*PageSize hs-18/HS 17.7mm:     "<</PageSize[50 283]/ImagingBBox null>>setpagedevice"
*PageSize hs-24/HS 23.6mm:     "<</PageSize[67 283]/ImagingBBox null>>setpagedevice"
*CloseUI: *PageSize
*OpenUI *PageRegion/Tape Width: PickOne
*OrderDependency: 10 AnySetup *PageRegion
*DefaultPageRegion: tz-12
*PageRegion tz-4/3.5mm:        "<</PageSize[10 283]/ImagingBBox null>>setpagedevice"
*PageRegion tz-6/6mm:          "<</PageSize[17 283]/ImagingBBox null>>setpagedevice"
*PageRegion tz-9/9mm:          "<</PageSize[26 283]/ImagingBBox null>>setpagedevice"
*PageRegion tz-12/12mm:        "<</PageSize[34 283]/ImagingBBox null>>setpagedevice"
*PageRegion tz-18/18mm:        "<</PageSize[51 283]/ImagingBBox null>>setpagedevice"
*PageRegion tz-24/24mm:        "<</PageSize[68 283]/ImagingBBox null>>setpagedevice"
*PageRegion tz-36/36mm:        "<</PageSize[102 283]/ImagingBBox null>>setpagedevice"
*PageRegion hs-6/HS 5.8mm:     "<</PageSize[16 283]/ImagingBBox null>>setpagedevice"
*PageRegion hs-9/HS 8.8mm:     "<</PageSize[25 283]/ImagingBBox null>>setpagedevice"
*PageRegion hs-12/HS 11.7mm:   "<</PageSize[33 283]/ImagingBBox null>>setpagedevice"
*PageRegion hs-18/HS 17.7mm:   "<</PageSize[50 283]/ImagingBBox null>>setpagedevice"
*PageRegion hs-24/HS 23.6mm:   "<</PageSize[67 283]/ImagingBBox null>>setpagedevice"
*CloseUI: *PageRegion
*DefaultImageableArea: tz-12
*ImageableArea tz-4/3.5mm:      "0 0 10 283"
*ImageableArea tz-6/6mm:        "0 0 17 283"
*ImageableArea tz-9/9mm:        "0 0 26 283"
*ImageableArea tz-12/12mm:      "0 0 34 283"
*ImageableArea tz-18/18mm:      "0 0 51 283"
*ImageableArea tz-24/24mm:      "0 0 68 283"
*ImageableArea tz-36/36mm:      "0 0 102 283"
*ImageableArea hs-6/HS 5.8mm:   "0 0 16 283"
*ImageableArea hs-9/HS 8.8mm:   "0 0 25 283"
*ImageableArea hs-12/HS 11.7mm: "0 0 33 283"
*ImageableArea hs-18/HS 17.7mm: "0 0 50 283"
*ImageableArea hs-24/HS 23.6mm: "0 0 67 283"
*DefaultPaperDimension: tz-12
*PaperDimension tz-4/3.5mm:      "10 283"
*PaperDimension tz-6/6mm:        "17 283"
*PaperDimension tz-9/9mm:        "26 283"
*PaperDimension tz-12/12mm:      "34 283"
*PaperDimension tz-18/18mm:      "51 283"
*PaperDimension tz-24/24mm:      "68 283"
*PaperDimension tz-36/36mm:      "102 283"
*PaperDimension hs-6/HS 5.8mm:   "16 283"
*PaperDimension hs-9/HS 8.8mm:   "25 283"
*PaperDimension hs-12/HS 11.7mm: "33 283"
*PaperDimension hs-18/HS 17.7mm: "50 283"
*PaperDimension hs-24/HS 23.6mm: "67 283"
*OpenUI *Resolution/Resolution: PickOne
*OrderDependency: 20 AnySetup *Resolution
*DefaultResolution: 360dpi
*Resolution 360x180dpi/360x180 DPI: "<</HWResolution[360 180]>>setpagedevice"
*Resolution 360dpi/360 DPI:          "<</HWResolution[360 360]>>setpagedevice"
*Resolution 360x720dpi/360x720 DPI:  "<</HWResolution[360 720]>>setpagedevice"
*CloseUI: *Resolution
*OpenUI *MirrorPrint/Mirror Print: PickOne
*OrderDependency: 30 AnySetup *MirrorPrint
*DefaultMirrorPrint: Normal
*MirrorPrint Normal/Normal: ""
*MirrorPrint Mirror/Mirror: ""
*CloseUI: *MirrorPrint
*OpenUI *HalfCut/Half Cut: PickOne
*OrderDependency: 30 AnySetup *HalfCut
*DefaultHalfCut: True
*HalfCut True/Yes: ""
*HalfCut False/No: ""
*CloseUI: *HalfCut
*OpenUI *CutLabel/Cut Label: PickOne
*OrderDependency: 30 AnySetup *CutLabel
*DefaultCutLabel: True
*CutLabel True/Yes: ""
*CutLabel False/No: ""
*CloseUI: *CutLabel
*DefaultFont: Courier
*Font Courier: Standard "(002.004S)" Standard ROM
*Font Courier-Bold: Standard "(002.004S)" Standard ROM
*Font Helvetica: Standard "(001.006S)" Standard ROM
*Font Helvetica-Bold: Standard "(001.007S)" Standard ROM
*Font Times-Roman: Standard "(001.007S)" Standard ROM
*Font Symbol: Special "(001.007S)" Special ROM
PPD

systemctl restart cups

echo "[7/7] Adding printer..."
lpadmin -x "$PRINTER_NAME" 2>/dev/null || true
lpadmin -p "$PRINTER_NAME" -E \
  -v "socket://$PRINTER_IP:9100" \
  -P "${PPD_DIR}/${PPD_NAME}"
lpadmin -p "$PRINTER_NAME" \
  -o PageSize=tz-12 \
  -o Resolution=360dpi \
  -o MirrorPrint=Normal
cupsenable "$PRINTER_NAME"
cupsaccept "$PRINTER_NAME"

ok "Brother P950NW added (filter built from source)."
lpstat -p "$PRINTER_NAME"
