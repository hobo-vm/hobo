// The install media's EFI\BOOT\BOOTAA64.EFI: starts the framebuffer driver, then Windows Boot Manager,
// which the media carries as EFI\BOOT\windows.efi so the firmware can't start it first. An installed
// VM needs no loader: the driver registered itself as a Driver#### option here.

#include "efi.h"

static const CHAR16 DriverPath[] = u"\\EFI\\hobo\\framebuffer.efi";
static const CHAR16 BootManagerPath[] = u"\\EFI\\BOOT\\windows.efi";

static EFI_GUID LoadedImageGuid = LOADED_IMAGE_GUID;
static EFI_GUID DevicePathGuid = DEVICE_PATH_GUID;

static EFI_BOOT_SERVICES *BS;

void *memcpy(void *destination, const void *source, UINTN count) { return hobo_copy(destination, source, count); }

void *memset(void *destination, int value, UINTN count) {
  UINT8 *d = destination;
  while (count--) *d++ = (UINT8)value;
  return destination;
}

static UINTN StringBytes(const CHAR16 *s) {
  UINTN n = 0;
  while (s[n]) n++;
  return (n + 1) * sizeof(CHAR16);
}

static UINTN NodeBytes(const EFI_DEVICE_PATH *node) { return node->Length[0] | ((UINTN)node->Length[1] << 8); }

// Loads a file from the volume this loader came from. Its device path is the volume's, then a file
// node, then an end node.
static EFI_STATUS LoadFromVolume(EFI_HANDLE self, EFI_HANDLE volume, const CHAR16 *file, EFI_HANDLE *image) {
  EFI_DEVICE_PATH *volumePath;
  EFI_STATUS status = BS->HandleProtocol(volume, &DevicePathGuid, (VOID **)&volumePath);
  if (EFI_ERROR(status)) return status;

  UINTN volumeBytes = 0;
  const EFI_DEVICE_PATH *node = volumePath;
  while (node->Type != END_DEVICE_PATH_TYPE) {
    volumeBytes += NodeBytes(node);
    node = (const EFI_DEVICE_PATH *)((const UINT8 *)node + NodeBytes(node));
  }

  UINTN fileBytes = StringBytes(file);
  UINT16 fileNodeBytes = (UINT16)(sizeof(EFI_DEVICE_PATH) + fileBytes);
  UINT8 *path;
  status = BS->AllocatePool(EfiLoaderData, volumeBytes + fileNodeBytes + sizeof(EFI_DEVICE_PATH), (VOID **)&path);
  if (EFI_ERROR(status)) return status;

  UINT8 *p = path;
  hobo_copy(p, volumePath, volumeBytes);
  p += volumeBytes;
  EFI_DEVICE_PATH fileNode = {MEDIA_DEVICE_PATH, MEDIA_FILEPATH_DP, {(UINT8)fileNodeBytes, (UINT8)(fileNodeBytes >> 8)}};
  hobo_copy(p, &fileNode, sizeof(fileNode));
  p += sizeof(fileNode);
  hobo_copy(p, file, fileBytes);
  p += fileBytes;
  EFI_DEVICE_PATH end = {END_DEVICE_PATH_TYPE, END_ENTIRE_DEVICE_PATH_SUBTYPE, {sizeof(EFI_DEVICE_PATH), 0}};
  hobo_copy(p, &end, sizeof(end));

  status = BS->LoadImage(0, self, (EFI_DEVICE_PATH *)path, 0, 0, image);
  BS->FreePool(path);
  return status;
}

EFI_STATUS efi_main(EFI_HANDLE self, EFI_SYSTEM_TABLE *system) {
  BS = system->BootServices;

  EFI_LOADED_IMAGE *loaded;
  EFI_STATUS status = BS->HandleProtocol(self, &LoadedImageGuid, (VOID **)&loaded);
  if (EFI_ERROR(status)) return status;

  // A failure here can only be that it's resident already, or Boot Manager stops the VM itself.
  EFI_HANDLE driver;
  if (!EFI_ERROR(LoadFromVolume(self, loaded->DeviceHandle, DriverPath, &driver))) BS->StartImage(driver, 0, 0);

  EFI_HANDLE bootManager;
  status = LoadFromVolume(self, loaded->DeviceHandle, BootManagerPath, &bootManager);
  if (EFI_ERROR(status)) return status;
  return BS->StartImage(bootManager, 0, 0);
}
