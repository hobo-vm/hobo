// A UEFI boot service driver that lets Windows boot on the Virtualization framework.
//
// VZ's firmware drives the virtio-gpu through a Graphics Output Protocol that only offers Blt, with
// no linear framebuffer, and Windows Boot Manager stops the VM without one. So this driver gives
// each GOP a framebuffer in reserved memory and, on a timer, Blts the rows that changed to the
// real display. Boot services end at ExitBootServices, and with them the timer; by then Windows
// has its own virtio-gpu driver coming (viogpudo).
//
// It registers itself as a Driver#### option with a bare file path, so the firmware loads it on
// each boot from whichever volume holds EFI\hobo\framebuffer.efi: the install media at first, then
// the Windows EFI partition. Being loaded before the firmware's consoles start, it also watches for
// GOPs that appear later.

#include "efi.h"

#define MAX_WIDTH 1920
#define MAX_HEIGHT 1200
#define BYTES_PER_PIXEL 4
#define FRAMEBUFFER_BYTES (MAX_WIDTH * MAX_HEIGHT * BYTES_PER_PIXEL)
#define FLUSH_INTERVAL_100NS 400000 // 40 ms
#define MAX_GOPS 8
#define MAX_DRIVER_OPTIONS 32
#define LOAD_OPTION_DESCRIPTION_OFFSET 6

static const CHAR16 DriverDescription[] = u"Hobo framebuffer";
static const CHAR16 DriverPath[] = u"\\EFI\\hobo\\framebuffer.efi";

static EFI_GUID GopGuid = GOP_GUID;
static EFI_GUID DevicePathGuid = DEVICE_PATH_GUID;
static EFI_GUID GlobalVariableGuid = GLOBAL_VARIABLE_GUID;
static EFI_GUID ExitBootServicesGroup = EXIT_BOOT_SERVICES_GROUP_GUID;
// Hobo's own: installed once this driver is resident, so a second load (the loader's, then the
// firmware's) steps aside.
static EFI_GUID ResidentGuid = {0x3c7d1b0e, 0x8a4f, 0x4e52, {0xb6, 0x19, 0x48, 0x4f, 0x42, 0x4f, 0x46, 0x42}};

typedef struct {
  EFI_HANDLE Handle;
  EFI_GOP *Gop;
  EFI_GOP_QUERY_MODE QueryMode;
  EFI_GOP_SET_MODE SetMode;
} TrackedGop;

static EFI_BOOT_SERVICES *BS;
static TrackedGop Gops[MAX_GOPS];
static UINTN GopCount;
// The virtio-gpu's GOP, the only one on a device; the console splitter's has no device path.
static TrackedGop *Display;
static UINT8 *Framebuffer;
static UINT8 *Shadow;
static EFI_EVENT FlushTimer;
static VOID *GopRegistration;
static volatile BOOLEAN BootServicesEnded;

// There's no libc, and the compiler can emit these calls for struct copies and loops.
void *memcpy(void *destination, const void *source, UINTN count) { return hobo_copy(destination, source, count); }

void *memset(void *destination, int value, UINTN count) {
  UINT8 *d = destination;
  while (count--) *d++ = (UINT8)value;
  return destination;
}

static BOOLEAN Fits(const EFI_GOP_MODE_INFO *info) {
  return info->HorizontalResolution <= MAX_WIDTH && info->VerticalResolution <= MAX_HEIGHT;
}

static VOID ClearFramebuffer(VOID) {
  memset(Framebuffer, 0, FRAMEBUFFER_BYTES);
  memset(Shadow, 0, FRAMEBUFFER_BYTES);
}

// Makes a GOP's current mode claim the framebuffer. The GOP can overwrite this at any mode change,
// including ones the console splitter makes underneath, so every flush does it again.
static VOID Advertise(EFI_GOP *gop) {
  EFI_GOP_MODE *mode = gop->Mode;
  if (!mode || !mode->Info || !Fits(mode->Info)) return;
  mode->Info->PixelFormat = PixelBlueGreenRedReserved8BitPerColor;
  mode->Info->PixelsPerScanLine = mode->Info->HorizontalResolution;
  mode->FrameBufferBase = (EFI_PHYSICAL_ADDRESS)(UINTN)Framebuffer;
  mode->FrameBufferSize = (UINTN)mode->Info->HorizontalResolution * mode->Info->VerticalResolution * BYTES_PER_PIXEL;
}

static TrackedGop *Tracked(EFI_GOP *gop) {
  for (UINTN i = 0; i < GopCount; i++) {
    if (Gops[i].Gop == gop) return &Gops[i];
  }
  return 0;
}

static EFI_STATUS QueryMode(EFI_GOP *self, UINT32 mode, UINTN *size, EFI_GOP_MODE_INFO **info) {
  EFI_STATUS status = Tracked(self)->QueryMode(self, mode, size, info);
  if (!EFI_ERROR(status) && Fits(*info)) {
    (*info)->PixelFormat = PixelBlueGreenRedReserved8BitPerColor;
    (*info)->PixelsPerScanLine = (*info)->HorizontalResolution;
  }
  return status;
}

static EFI_STATUS SetMode(EFI_GOP *self, UINT32 mode) {
  TrackedGop *tracked = Tracked(self);
  UINTN size;
  EFI_GOP_MODE_INFO *info;
  EFI_STATUS status = tracked->QueryMode(self, mode, &size, &info);
  if (EFI_ERROR(status)) return status;
  BOOLEAN fits = Fits(info);
  BS->FreePool(info);
  if (!fits) return EFI_UNSUPPORTED;

  status = tracked->SetMode(self, mode);
  if (!EFI_ERROR(status)) {
    // The firmware has cleared the display, so a blank framebuffer matches it.
    ClearFramebuffer();
    Advertise(self);
  }
  return status;
}

// Boots with the framebuffer's largest mode if the firmware started above it, which it does for a
// display size it doesn't list.
static VOID SelectFittingMode(TrackedGop *tracked) {
  EFI_GOP_MODE *mode = tracked->Gop->Mode;
  if (mode->Info && Fits(mode->Info)) return;
  UINT64 bestArea = 0;
  UINT32 best = mode->MaxMode;
  for (UINT32 i = 0; i < mode->MaxMode; i++) {
    UINTN size;
    EFI_GOP_MODE_INFO *info;
    if (EFI_ERROR(tracked->QueryMode(tracked->Gop, i, &size, &info))) continue;
    UINT64 area = (UINT64)info->HorizontalResolution * info->VerticalResolution;
    if (Fits(info) && area > bestArea) {
      bestArea = area;
      best = i;
    }
    BS->FreePool(info);
  }
  if (best < mode->MaxMode) tracked->SetMode(tracked->Gop, best);
}

static VOID Track(EFI_HANDLE handle) {
  EFI_GOP *gop;
  if (EFI_ERROR(BS->HandleProtocol(handle, &GopGuid, (VOID **)&gop)) || Tracked(gop) || GopCount == MAX_GOPS) return;

  TrackedGop *tracked = &Gops[GopCount++];
  tracked->Handle = handle;
  tracked->Gop = gop;
  tracked->QueryMode = gop->QueryMode;
  tracked->SetMode = gop->SetMode;
  gop->QueryMode = QueryMode;
  gop->SetMode = SetMode;

  VOID *path;
  if (!EFI_ERROR(BS->HandleProtocol(handle, &DevicePathGuid, &path))) {
    Display = tracked;
    SelectFittingMode(tracked);
  }
  Advertise(gop);
}

static VOID GopAppeared(EFI_EVENT event, VOID *context) {
  (void)event;
  (void)context;
  EFI_HANDLE handle;
  UINTN size = sizeof(handle);
  while (!EFI_ERROR(BS->LocateHandle(ByRegisterNotify, 0, GopRegistration, &size, &handle))) {
    Track(handle);
    size = sizeof(handle);
  }
}

// A GOP's driver can be stopped when the firmware reconnects its consoles, and its memory goes too.
static VOID ForgetStoppedGops(VOID) {
  for (UINTN i = 0; i < GopCount;) {
    EFI_GOP *gop;
    if (EFI_ERROR(BS->HandleProtocol(Gops[i].Handle, &GopGuid, (VOID **)&gop)) || gop != Gops[i].Gop) {
      if (Display == &Gops[i]) Display = 0;
      Gops[i] = Gops[--GopCount];
      if (Display == &Gops[GopCount]) Display = &Gops[i];
    } else {
      i++;
    }
  }
}

static BOOLEAN RowChanged(const UINT8 *row, const UINT8 *shadow, UINTN bytes) {
  const UINT64 *a = (const UINT64 *)row, *b = (const UINT64 *)shadow;
  for (UINTN i = 0; i < bytes / sizeof(UINT64); i++) {
    if (a[i] != b[i]) return 1;
  }
  return 0;
}

static VOID Flush(EFI_EVENT event, VOID *context) {
  (void)event;
  (void)context;
  if (BootServicesEnded) return;
  ForgetStoppedGops();
  for (UINTN i = 0; i < GopCount; i++) Advertise(Gops[i].Gop);
  if (!Display || !Display->Gop->Mode->Info || !Fits(Display->Gop->Mode->Info)) return;

  EFI_GOP *gop = Display->Gop;
  UINTN width = gop->Mode->Info->HorizontalResolution;
  UINTN height = gop->Mode->Info->VerticalResolution;
  UINTN stride = width * BYTES_PER_PIXEL;
  // Blts each run of changed rows as one. A pass over the row past the end finishes a run reaching it.
  UINTN noRun = height;
  UINTN runStart = noRun;
  for (UINTN y = 0; y <= height; y++) {
    BOOLEAN changed = y < height && RowChanged(Framebuffer + y * stride, Shadow + y * stride, stride);
    if (changed && runStart == noRun) runStart = y;
    if (!changed && runStart != noRun) {
      gop->Blt(gop, Framebuffer, EfiBltBufferToVideo, 0, runStart, 0, runStart, width, y - runStart, stride);
      hobo_copy(Shadow + runStart * stride, Framebuffer + runStart * stride, (y - runStart) * stride);
      runStart = noRun;
    }
  }
}

static VOID BootServicesEnding(EFI_EVENT event, VOID *context) {
  (void)event;
  (void)context;
  BootServicesEnded = 1;
}

static UINTN StringBytes(const CHAR16 *s) {
  UINTN n = 0;
  while (s[n]) n++;
  return (n + 1) * sizeof(CHAR16);
}

static BOOLEAN BytesEqual(const VOID *a, const VOID *b, UINTN count) {
  const UINT8 *x = a, *y = b;
  while (count--) {
    if (*x++ != *y++) return 0;
  }
  return 1;
}

static VOID DriverVariableName(CHAR16 *name, UINT16 number) {
  static const CHAR16 hex[] = u"0123456789ABCDEF";
  const CHAR16 prefix[] = u"Driver";
  for (UINTN i = 0; i < 6; i++) name[i] = prefix[i];
  for (UINTN i = 0; i < 4; i++) name[6 + i] = hex[(number >> (12 - i * 4)) & 0xf];
  name[10] = 0;
}

// Adds this driver to the firmware's Driver#### options, unless a previous boot already did. An
// EFI_LOAD_OPTION is: attributes (4 bytes), device path bytes (2), description, device path.
static VOID RegisterDriverOption(EFI_RUNTIME_SERVICES *runtime) {
  UINT16 order[MAX_DRIVER_OPTIONS];
  UINTN orderBytes = sizeof(order);
  if (EFI_ERROR(runtime->GetVariable(u"DriverOrder", &GlobalVariableGuid, 0, &orderBytes, order))) orderBytes = 0;
  UINTN count = orderBytes / sizeof(UINT16);
  if (count == MAX_DRIVER_OPTIONS) return;

  CHAR16 name[11];
  UINT8 option[256];
  UINTN descriptionBytes = StringBytes(DriverDescription);
  for (UINTN i = 0; i < count; i++) {
    UINTN size = sizeof(option);
    DriverVariableName(name, order[i]);
    if (EFI_ERROR(runtime->GetVariable(name, &GlobalVariableGuid, 0, &size, option))) continue;
    if (size >= LOAD_OPTION_DESCRIPTION_OFFSET + descriptionBytes &&
        BytesEqual(option + LOAD_OPTION_DESCRIPTION_OFFSET, DriverDescription, descriptionBytes)) return;
  }

  UINT16 number = 0;
  for (;; number++) {
    UINTN size = sizeof(option);
    DriverVariableName(name, number);
    if (runtime->GetVariable(name, &GlobalVariableGuid, 0, &size, option) == EFI_NOT_FOUND) break;
  }

  UINTN pathBytes = StringBytes(DriverPath);
  UINT16 fileNodeBytes = (UINT16)(sizeof(EFI_DEVICE_PATH) + pathBytes);
  UINT16 listBytes = (UINT16)(fileNodeBytes + sizeof(EFI_DEVICE_PATH));
  UINT32 attributes = 1; // LOAD_OPTION_ACTIVE
  UINT8 *p = option;
  hobo_copy(p, &attributes, 4);
  p += 4;
  hobo_copy(p, &listBytes, 2);
  p += 2;
  hobo_copy(p, DriverDescription, descriptionBytes);
  p += descriptionBytes;
  EFI_DEVICE_PATH node = {MEDIA_DEVICE_PATH, MEDIA_FILEPATH_DP, {(UINT8)fileNodeBytes, (UINT8)(fileNodeBytes >> 8)}};
  hobo_copy(p, &node, sizeof(node));
  p += sizeof(node);
  hobo_copy(p, DriverPath, pathBytes);
  p += pathBytes;
  EFI_DEVICE_PATH end = {END_DEVICE_PATH_TYPE, END_ENTIRE_DEVICE_PATH_SUBTYPE, {sizeof(EFI_DEVICE_PATH), 0}};
  hobo_copy(p, &end, sizeof(end));
  p += sizeof(end);

  UINT32 saved = EFI_VARIABLE_NON_VOLATILE | EFI_VARIABLE_BOOTSERVICE_ACCESS | EFI_VARIABLE_RUNTIME_ACCESS;
  if (EFI_ERROR(runtime->SetVariable(name, &GlobalVariableGuid, saved, (UINTN)(p - option), option))) return;
  order[count] = number;
  runtime->SetVariable(u"DriverOrder", &GlobalVariableGuid, saved, (count + 1) * sizeof(UINT16), order);
}

EFI_STATUS efi_main(EFI_HANDLE image, EFI_SYSTEM_TABLE *system) {
  (void)image;
  BS = system->BootServices;

  VOID *resident;
  if (!EFI_ERROR(BS->LocateProtocol(&ResidentGuid, 0, &resident))) return EFI_ALREADY_STARTED;

  EFI_PHYSICAL_ADDRESS framebuffer, shadow;
  UINTN pages = (FRAMEBUFFER_BYTES + 4095) / 4096;
  // Reserved so that Windows leaves it alone for as long as it draws to it.
  EFI_STATUS status = BS->AllocatePages(AllocateAnyPages, EfiReservedMemoryType, pages, &framebuffer);
  if (EFI_ERROR(status)) return status;
  status = BS->AllocatePages(AllocateAnyPages, EfiBootServicesData, pages, &shadow);
  if (EFI_ERROR(status)) return status;
  Framebuffer = (UINT8 *)(UINTN)framebuffer;
  Shadow = (UINT8 *)(UINTN)shadow;
  ClearFramebuffer();

  EFI_HANDLE residentHandle = 0;
  status = BS->InstallProtocolInterface(&residentHandle, &ResidentGuid, 0, 0);
  if (EFI_ERROR(status)) return status;

  RegisterDriverOption(system->RuntimeServices);

  EFI_EVENT appeared, ending;
  if (!EFI_ERROR(BS->CreateEvent(EVT_NOTIFY_SIGNAL, TPL_CALLBACK, GopAppeared, 0, &appeared))) {
    BS->RegisterProtocolNotify(&GopGuid, appeared, &GopRegistration);
  }
  UINTN count = 0;
  EFI_HANDLE *handles;
  if (!EFI_ERROR(BS->LocateHandleBuffer(ByProtocol, &GopGuid, 0, &count, &handles))) {
    for (UINTN i = 0; i < count; i++) Track(handles[i]);
    BS->FreePool(handles);
  }

  status = BS->CreateEventEx(EVT_NOTIFY_SIGNAL, TPL_NOTIFY, BootServicesEnding, 0, &ExitBootServicesGroup, &ending);
  if (EFI_ERROR(status)) return status;
  status = BS->CreateEvent(EVT_TIMER | EVT_NOTIFY_SIGNAL, TPL_CALLBACK, Flush, 0, &FlushTimer);
  if (EFI_ERROR(status)) return status;
  return BS->SetTimer(FlushTimer, TimerPeriodic, FLUSH_INTERVAL_100NS);
}
