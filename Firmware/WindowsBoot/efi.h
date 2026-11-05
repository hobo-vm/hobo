// The parts of the UEFI 2.x interfaces the Windows boot driver and loader use, as the spec lays them out.
#pragma once

typedef unsigned char UINT8;
typedef unsigned short UINT16;
typedef unsigned int UINT32;
typedef unsigned long long UINT64;
typedef UINT64 UINTN;
typedef unsigned short CHAR16;
typedef unsigned char BOOLEAN;
typedef void VOID;
typedef UINTN EFI_STATUS;
typedef VOID *EFI_HANDLE;
typedef VOID *EFI_EVENT;
typedef UINT64 EFI_PHYSICAL_ADDRESS;

#define EFI_ERROR_BIT (1ULL << 63)
#define EFI_ERROR(status) (((status) & EFI_ERROR_BIT) != 0)
#define EFI_SUCCESS 0ULL
#define EFI_UNSUPPORTED (EFI_ERROR_BIT | 3)
#define EFI_BUFFER_TOO_SMALL (EFI_ERROR_BIT | 5)
#define EFI_NOT_FOUND (EFI_ERROR_BIT | 14)
#define EFI_ALREADY_STARTED (EFI_ERROR_BIT | 20)

typedef struct {
  UINT32 Data1;
  UINT16 Data2;
  UINT16 Data3;
  UINT8 Data4[8];
} EFI_GUID;

typedef struct {
  UINT64 Signature;
  UINT32 Revision;
  UINT32 HeaderSize;
  UINT32 CRC32;
  UINT32 Reserved;
} EFI_TABLE_HEADER;

// Device paths are byte-packed: a node's fields can sit at any address.
typedef struct {
  UINT8 Type;
  UINT8 SubType;
  UINT8 Length[2];
} EFI_DEVICE_PATH;

#define MEDIA_DEVICE_PATH 4
#define MEDIA_FILEPATH_DP 4
#define END_DEVICE_PATH_TYPE 0x7f
#define END_ENTIRE_DEVICE_PATH_SUBTYPE 0xff

// Allocation
#define AllocateAnyPages 0
#define EfiLoaderData 2
#define EfiBootServicesData 4
#define EfiReservedMemoryType 0

// Events
#define EVT_TIMER 0x80000000u
#define EVT_NOTIFY_SIGNAL 0x00000200u
#define TPL_CALLBACK 8
#define TPL_NOTIFY 16
#define TimerPeriodic 1

// Protocol lookups
#define ByRegisterNotify 1
#define ByProtocol 2

typedef VOID (*EFI_EVENT_NOTIFY)(EFI_EVENT event, VOID *context);

typedef struct {
  EFI_TABLE_HEADER Hdr;
  VOID *RaiseTPL;
  VOID *RestoreTPL;
  EFI_STATUS (*AllocatePages)(UINTN type, UINTN memoryType, UINTN pages, EFI_PHYSICAL_ADDRESS *memory);
  VOID *FreePages;
  VOID *GetMemoryMap;
  EFI_STATUS (*AllocatePool)(UINTN poolType, UINTN size, VOID **buffer);
  EFI_STATUS (*FreePool)(VOID *buffer);
  EFI_STATUS (*CreateEvent)(UINT32 type, UINTN tpl, EFI_EVENT_NOTIFY notify, VOID *context, EFI_EVENT *event);
  EFI_STATUS (*SetTimer)(EFI_EVENT event, UINTN type, UINT64 triggerTime);
  VOID *WaitForEvent;
  VOID *SignalEvent;
  VOID *CloseEvent;
  VOID *CheckEvent;
  EFI_STATUS (*InstallProtocolInterface)(EFI_HANDLE *handle, EFI_GUID *protocol, UINTN interfaceType, VOID *interface);
  VOID *ReinstallProtocolInterface;
  VOID *UninstallProtocolInterface;
  EFI_STATUS (*HandleProtocol)(EFI_HANDLE handle, EFI_GUID *protocol, VOID **interface);
  VOID *Reserved;
  EFI_STATUS (*RegisterProtocolNotify)(EFI_GUID *protocol, EFI_EVENT event, VOID **registration);
  EFI_STATUS (*LocateHandle)(UINTN searchType, EFI_GUID *protocol, VOID *searchKey, UINTN *bufferSize, EFI_HANDLE *buffer);
  VOID *LocateDevicePath;
  VOID *InstallConfigurationTable;
  EFI_STATUS (*LoadImage)(BOOLEAN bootPolicy, EFI_HANDLE parent, EFI_DEVICE_PATH *path, VOID *source, UINTN sourceSize, EFI_HANDLE *image);
  EFI_STATUS (*StartImage)(EFI_HANDLE image, UINTN *exitDataSize, CHAR16 **exitData);
  VOID *Exit;
  VOID *UnloadImage;
  VOID *ExitBootServices;
  VOID *GetNextMonotonicCount;
  VOID *Stall;
  VOID *SetWatchdogTimer;
  VOID *ConnectController;
  VOID *DisconnectController;
  VOID *OpenProtocol;
  VOID *CloseProtocol;
  VOID *OpenProtocolInformation;
  VOID *ProtocolsPerHandle;
  EFI_STATUS (*LocateHandleBuffer)(UINTN searchType, EFI_GUID *protocol, VOID *searchKey, UINTN *count, EFI_HANDLE **buffer);
  EFI_STATUS (*LocateProtocol)(EFI_GUID *protocol, VOID *registration, VOID **interface);
  VOID *InstallMultipleProtocolInterfaces;
  VOID *UninstallMultipleProtocolInterfaces;
  VOID *CalculateCrc32;
  VOID *CopyMem;
  VOID *SetMem;
  EFI_STATUS (*CreateEventEx)(UINT32 type, UINTN tpl, EFI_EVENT_NOTIFY notify, const VOID *context, const EFI_GUID *group, EFI_EVENT *event);
} EFI_BOOT_SERVICES;

#define EFI_VARIABLE_NON_VOLATILE 1
#define EFI_VARIABLE_BOOTSERVICE_ACCESS 2
#define EFI_VARIABLE_RUNTIME_ACCESS 4

typedef struct {
  EFI_TABLE_HEADER Hdr;
  VOID *GetTime;
  VOID *SetTime;
  VOID *GetWakeupTime;
  VOID *SetWakeupTime;
  VOID *SetVirtualAddressMap;
  VOID *ConvertPointer;
  EFI_STATUS (*GetVariable)(const CHAR16 *name, EFI_GUID *vendor, UINT32 *attributes, UINTN *size, VOID *data);
  VOID *GetNextVariableName;
  EFI_STATUS (*SetVariable)(const CHAR16 *name, EFI_GUID *vendor, UINT32 attributes, UINTN size, VOID *data);
} EFI_RUNTIME_SERVICES;

typedef struct {
  EFI_TABLE_HEADER Hdr;
  CHAR16 *FirmwareVendor;
  UINT32 FirmwareRevision;
  EFI_HANDLE ConsoleInHandle;
  VOID *ConIn;
  EFI_HANDLE ConsoleOutHandle;
  VOID *ConOut;
  EFI_HANDLE StandardErrorHandle;
  VOID *StdErr;
  EFI_RUNTIME_SERVICES *RuntimeServices;
  EFI_BOOT_SERVICES *BootServices;
} EFI_SYSTEM_TABLE;

typedef struct {
  UINT32 Revision;
  EFI_HANDLE ParentHandle;
  EFI_SYSTEM_TABLE *SystemTable;
  EFI_HANDLE DeviceHandle;
} EFI_LOADED_IMAGE;

// Graphics Output Protocol
#define PixelBlueGreenRedReserved8BitPerColor 1
#define PixelBltOnly 3
#define EfiBltBufferToVideo 2

typedef struct {
  UINT32 Version;
  UINT32 HorizontalResolution;
  UINT32 VerticalResolution;
  UINT32 PixelFormat;
  UINT32 PixelInformation[4];
  UINT32 PixelsPerScanLine;
} EFI_GOP_MODE_INFO;

typedef struct {
  UINT32 MaxMode;
  UINT32 Mode;
  EFI_GOP_MODE_INFO *Info;
  UINTN SizeOfInfo;
  EFI_PHYSICAL_ADDRESS FrameBufferBase;
  UINTN FrameBufferSize;
} EFI_GOP_MODE;

typedef struct EFI_GOP EFI_GOP;
typedef EFI_STATUS (*EFI_GOP_QUERY_MODE)(EFI_GOP *self, UINT32 mode, UINTN *size, EFI_GOP_MODE_INFO **info);
typedef EFI_STATUS (*EFI_GOP_SET_MODE)(EFI_GOP *self, UINT32 mode);
typedef EFI_STATUS (*EFI_GOP_BLT)(EFI_GOP *self, VOID *buffer, UINTN operation, UINTN sourceX, UINTN sourceY,
                                  UINTN destinationX, UINTN destinationY, UINTN width, UINTN height, UINTN delta);

struct EFI_GOP {
  EFI_GOP_QUERY_MODE QueryMode;
  EFI_GOP_SET_MODE SetMode;
  EFI_GOP_BLT Blt;
  EFI_GOP_MODE *Mode;
};

#define GOP_GUID {0x9042a9de, 0x23dc, 0x4a38, {0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a}}
#define DEVICE_PATH_GUID {0x09576e91, 0x6d3f, 0x11d2, {0x8e, 0x39, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b}}
#define LOADED_IMAGE_GUID {0x5b1b31a1, 0x9562, 0x11d2, {0x8e, 0x3f, 0x00, 0xa0, 0xc9, 0x69, 0x72, 0x3b}}
#define GLOBAL_VARIABLE_GUID {0x8be4df61, 0x93ca, 0x11d2, {0xaa, 0x0d, 0x00, 0xe0, 0x98, 0x03, 0x2b, 0x8c}}
#define EXIT_BOOT_SERVICES_GROUP_GUID {0x27abf055, 0xb1b8, 0x4c26, {0x80, 0x48, 0x74, 0x8f, 0x37, 0xba, 0xa2, 0xdf}}

// The compiler may turn loops into calls to these even with -fno-builtin, and there's no libc here.
static inline void *hobo_copy(void *destination, const void *source, UINTN count) {
  UINT8 *d = destination;
  const UINT8 *s = source;
  while (count--) *d++ = *s++;
  return destination;
}
