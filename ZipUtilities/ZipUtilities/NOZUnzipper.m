//
//  NOZUnzipper.m
//  ZipUtilities
//
//  The MIT License (MIT)
//
//  Copyright (c) 2015 Nolan O'Brien
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

#import "NOZ_Project.h"
#import "NOZError.h"
#import "NOZUnzipper.h"
#import "NOZUtils_Project.h"

#include "zlib.h"

static BOOL noz_fread_value(FILE *file, Byte* value, const UInt8 byteCount);

#define PRIVATE_READ(file, value) noz_fread_value(file, (Byte *)&value, sizeof(value))

@interface NOZCentralDirectoryRecord ()
- (instancetype)initWithOwner:(NOZCentralDirectory *)cd;
- (NOZFileEntryT *)internalEntry;
- (NOZErrorCode)validate;
- (BOOL)isOwnedByCentralDirectory:(NOZCentralDirectory *)cd;
@end

@interface NOZCentralDirectory ()
- (nonnull instancetype)initWithKnownFileSize:(SInt64)fileSize NS_DESIGNATED_INITIALIZER;
@end

@interface NOZCentralDirectory (Protected)
- (NSArray *)internalRecords;
- (BOOL)readEndOfCentralDirectoryRecordAtPosition:(off_t)eocdPos inFile:(FILE*)file;
- (BOOL)readCentralDirectoryEntriesWithFile:(FILE*)file;
- (NOZCentralDirectoryRecord *)readCentralDirectoryEntryAtCurrentPositionWithFile:(FILE*)file;
- (BOOL)validateCentralDirectoryAndReturnError:(NSError **)error;
- (NOZCentralDirectoryRecord *)recordAtIndex:(NSUInteger)index;
- (NSUInteger)indexForRecordWithName:(NSString *)name;
@end

@interface NOZUnzipper (Private)
- (SInt64)private_locateSignature:(UInt32)signature;
- (BOOL)private_locateCompressedDataOfRecord:(NOZCentralDirectoryRecord *)record;
- (BOOL)private_deflateWithProgressBlock:(nullable NOZProgressBlock)progressBlock
                              usingBlock:(nonnull NOZUnzipByteRangeEnumerationBlock)block;
@end

@implementation NOZUnzipper
{
    NSString *_standardizedFilePath;

    struct {
        FILE* file;

        off_t endOfCentralDirectorySignaturePosition;
        off_t endOfFilePosition;
    } _internal;

    struct {
        z_stream zStream;
        off_t offsetToFirstByte;
        UInt32 crc32;

        NOZFileEntryT *entry;

        BOOL isUnzipping:YES;
    } _currentUnzipping;
}

-(void)dealloc
{
    [self closeAndReturnError:NULL];
}

- (nonnull instancetype)initWithZipFile:(nonnull NSString *)zipFilePath
{
    if (self = [super init]) {
        _zipFilePath = [zipFilePath copy];
    }
    return self;
}

- (instancetype)init
{
    [self doesNotRecognizeSelector:_cmd];
    abort();
}

- (BOOL)openAndReturnError:(out NSError *__autoreleasing  __nullable * __nullable)error
{
    NSError *stackError = NOZError(NOZErrorCodeUnzipCannotOpenZip, @{ @"zipFilePath" : [self zipFilePath] ?: [NSNull null] });
    _standardizedFilePath = [self.zipFilePath stringByStandardizingPath];
    if (_standardizedFilePath.UTF8String) {
        _internal.file = fopen(_standardizedFilePath.UTF8String, "r");
        if (_internal.file) {
            _internal.endOfFilePosition = fseeko(_internal.file, 0, SEEK_END);
            _internal.endOfCentralDirectorySignaturePosition = [self private_locateSignature:NOZMagicNumberEndOfCentralDirectoryRecord];
            if (_internal.endOfCentralDirectorySignaturePosition) {
                return YES;
            } else {
                [self closeAndReturnError:NULL];
                stackError = NOZError(NOZErrorCodeUnzipInvalidZipFile, @{ @"zipFilePath" : self.zipFilePath });
            }
        }
    }

    if (error) {
        *error = stackError;
    }
    return NO;
}

- (BOOL)closeAndReturnError:(out NSError *__autoreleasing  __nullable * __nullable)error
{
    _centralDirectory = nil;
    if (_internal.file) {
        fclose(_internal.file);
        _internal.file = NULL;
    }
    return YES;
}

- (nullable NOZCentralDirectory *)readCentralDirectoryAndReturnError:(out NSError * __nullable * __nullable)error
{
    __block NSError *stackError = nil;
    noz_defer(^{
        if (stackError && error) {
            *error = stackError;
        }
    });

    if (!_internal.file || !_internal.endOfCentralDirectorySignaturePosition) {
        stackError = NOZError(NOZErrorCodeUnzipMustOpenUnzipperBeforeManipulating, nil);
        return nil;
    }

    NOZCentralDirectory *cd = [[NOZCentralDirectory alloc] initWithKnownFileSize:_internal.endOfFilePosition];
    if (![cd readEndOfCentralDirectoryRecordAtPosition:_internal.endOfCentralDirectorySignaturePosition inFile:_internal.file]) {
        stackError = NOZError(NOZErrorCodeUnzipCannotReadCentralDirectory, nil);
        return nil;
    }

    if (![cd readCentralDirectoryEntriesWithFile:_internal.file]) {
        stackError = NOZError(NOZErrorCodeUnzipCannotReadCentralDirectory, nil);
        return nil;
    }

    if (![cd validateCentralDirectoryAndReturnError:&stackError]) {
        return nil;
    }

    _centralDirectory = cd;
    return cd;
}

- (nullable NOZCentralDirectoryRecord *)readRecordAtIndex:(NSUInteger)index error:(out NSError * __nullable * __nullable)error
{
    if (index >= _centralDirectory.recordCount) {
        if (error) {
            *error = NOZError(NOZErrorCodeUnzipIndexOutOfBounds, nil);
        }
        return nil;
    }
    return [_centralDirectory recordAtIndex:index];
}

- (NSUInteger)indexForRecordWithName:(nonnull NSString *)name
{
    return (_centralDirectory) ? [_centralDirectory indexForRecordWithName:name] : NSNotFound;
}

- (void)enumerateManifestEntriesUsingBlock:(nonnull NOZUnzipRecordEnumerationBlock)block
{
    [_centralDirectory.internalRecords enumerateObjectsUsingBlock:block];
}

- (nullable NSError *)enumerateByteRangesOfRecord:(nonnull NOZCentralDirectoryRecord *)record
                                    progressBlock:(nullable NOZProgressBlock)progressBlock
                                       usingBlock:(nonnull NOZUnzipByteRangeEnumerationBlock)block
{
    if (!_internal.file) {
        return NOZError(NOZErrorCodeUnzipMustOpenUnzipperBeforeManipulating, nil);
    }

    if (![record isOwnedByCentralDirectory:_centralDirectory]) {
        return NOZError(NOZErrorCodeUnzipCannotReadFileEntry, nil);
    }

    if (![self private_locateCompressedDataOfRecord:record]) {
        return NOZError(NOZErrorCodeUnzipCannotReadFileEntry, nil);
    }

    _currentUnzipping.isUnzipping = YES;
    noz_defer(^{ _currentUnzipping.isUnzipping = NO; });

    _currentUnzipping.offsetToFirstByte = ftello(_internal.file);
    if (_currentUnzipping.offsetToFirstByte == -1) {
        return NOZError(NOZErrorCodeUnzipCannotReadFileEntry, nil);
    }

    _currentUnzipping.crc32 = 0;
    _currentUnzipping.zStream.zalloc = NULL;
    _currentUnzipping.zStream.zfree = NULL;
    _currentUnzipping.zStream.opaque = NULL;
    _currentUnzipping.zStream.next_in = 0;
    _currentUnzipping.zStream.avail_in = 0;

    if (Z_OK != inflateInit2(&_currentUnzipping.zStream, -MAX_WBITS)) {
        return NOZError(NOZErrorCodeUnzipCannotDecompressFileEntry, nil);
    }
    noz_defer(^{ inflateEnd(&_currentUnzipping.zStream); });

    _currentUnzipping.entry = record.internalEntry;
    noz_defer(^{ _currentUnzipping.entry = NULL; });

    if (![self private_deflateWithProgressBlock:progressBlock usingBlock:block]) {
        return NOZError(NOZErrorCodeUnzipCannotDecompressFileEntry, nil);
    }

    return nil;
}

- (NSData *)readDataFromRecord:(nonnull NOZCentralDirectoryRecord *)record
                 progressBlock:(nullable NOZProgressBlock)progressBlock
                         error:(out NSError * __nullable __autoreleasing * __nullable)error
{
    __block NSMutableData *data = nil;
    NSError *stackError = [self enumerateByteRangesOfRecord:record
                                              progressBlock:progressBlock
                                                 usingBlock:^(const void * __nonnull bytes, NSRange byteRange, BOOL * __nonnull stop) {
                                                     if (!data) {
                                                         data = [NSMutableData dataWithCapacity:byteRange.length];
                                                     }
                                                     [data appendBytes:bytes length:byteRange.length];
                                                 }];

    if (stackError) {
        data = nil;
        if (error) {
            *error = stackError;
        }
    }

    return data;
}

- (BOOL)saveRecord:(nonnull NOZCentralDirectoryRecord *)record
       toDirectory:(nonnull NSString *)destinationRootDirectory
   shouldOverwrite:(BOOL)overwrite
     progressBlock:(nullable NOZProgressBlock)progressBlock
             error:(out NSError * __nullable __autoreleasing * __nullable)error
{
    __block NSError *stackError = nil;
    noz_defer(^{
        if (stackError && error) {
            *error = stackError;
        }
    });
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *destinationFile = [[destinationRootDirectory stringByAppendingPathComponent:record.name] stringByStandardizingPath];

    if (![fm createDirectoryAtPath:[destinationFile stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }

    FILE *file = fopen(destinationFile.UTF8String, overwrite ? "w+" : "r+");
    if (!file) {
        stackError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return NO;
    }

    NSDate *fileDate = noz_NSDate_from_dos_date(record.internalEntry->fileHeader.dosDate, record.internalEntry->fileHeader.dosTime);

    noz_defer(^{
        off_t offset = ftello(file);
        fclose(file);
        if (offset == 0) {
            [[NSFileManager defaultManager] removeItemAtPath:destinationFile error:NULL];
        } else if (fileDate) {
            [[NSFileManager defaultManager] setAttributes:@{ NSFileModificationDate : fileDate }
                                             ofItemAtPath:destinationFile
                                                    error:NULL];
        }
    });

    stackError = [self enumerateByteRangesOfRecord:record
                                     progressBlock:progressBlock
                                        usingBlock:^(const void * __nonnull bytes, NSRange byteRange, BOOL * __nonnull stop) {
                                            if (fwrite(bytes, 1, byteRange.length, file) != byteRange.length) {
                                                *stop = YES;
                                            } else {
#if DEBUG
                                                if ((byteRange.length + byteRange.location) == _currentUnzipping.entry->fileDescriptor.uncompressedSize) {
                                                    fflush(file);
                                                }
#endif
                                            }
                                        }];

    if (stackError) {
        return NO;
    }

    return YES;
}

@end

@implementation NOZUnzipper (Private)

- (off_t)private_locateSignature:(UInt32)signature
{
    Byte sig[4];

#if __BIG_ENDIAN__
    sig[0] = ((Byte*)(&signature))[3];
    sig[1] = ((Byte*)(&signature))[2];
    sig[2] = ((Byte*)(&signature))[1];
    sig[3] = ((Byte*)(&signature))[0];
#else
    sig[0] = ((Byte*)(&signature))[0];
    sig[1] = ((Byte*)(&signature))[1];
    sig[2] = ((Byte*)(&signature))[2];
    sig[3] = ((Byte*)(&signature))[3];
#endif

    const size_t pageSize = NSPageSize();
    Byte buffer[pageSize];
    size_t bytesRead = 0;
    size_t maxBytes = UINT16_MAX /* max global comment size */ + 22 /* End of Central Directory Record size */;

    if (0 != fseeko(_internal.file, 0, SEEK_END)) {
        return 0;
    }

    size_t fileSize = (size_t)ftello(_internal.file);
    if (maxBytes > fileSize) {
        maxBytes = fileSize;
    }

    while (bytesRead < maxBytes) {
        size_t sizeToRead = sizeof(buffer);
        if (sizeToRead > (maxBytes - bytesRead)) {
            sizeToRead = maxBytes - bytesRead;
        }
        if (sizeToRead < 4) {
            return 0;
        }

        off_t position = (off_t)fileSize - (off_t)bytesRead - (off_t)sizeToRead;
        if (0 != fseeko(_internal.file, position, SEEK_SET)) {
            return 0;
        }

        if (sizeToRead != fread(buffer, 1, sizeToRead, _internal.file)) {
            return 0;
        }

        for (off_t i = (off_t)(sizeToRead - 3); i >= 0; i--) {
            if (buffer[i + 3] == sig[3]) {
                if (buffer[i + 2] == sig[2]) {
                    if (buffer[i + 1] == sig[1]) {
                        if (buffer[i + 0] == sig[0]) {
                            return (off_t)(position + i);
                        }
                    }
                }
            }
        }

        bytesRead += sizeToRead - 3;
    }

    return 0;
}

- (BOOL)private_locateCompressedDataOfRecord:(NOZCentralDirectoryRecord *)record
{
    NOZFileEntryT *entry = record.internalEntry;
    if (!entry) {
        return NO;
    }

    if (0 != fseeko(_internal.file, entry->centralDirectoryRecord.localFileHeaderOffsetFromStartOfDisk, SEEK_SET)) {
        return NO;
    }

    UInt32 signature = 0;
    if (!PRIVATE_READ(_internal.file, signature) || signature != NOZMagicNumberLocalFileHeader) {
        return NO;
    }

    UInt16 nameSize, extraFieldSize;

    off_t seek =    2 + // versionForExtraction
                    2 + // bitFlag
                    2 + // compressionMethod
                    2 + // dosTime
                    2 + // dosDate
                    4 + // crc32
                    4 + // compressed size
                    4 + // decompressed size
                    0;

    if (0 != fseeko(_internal.file, seek, SEEK_CUR)) {
        return NO;
    }

    if (!PRIVATE_READ(_internal.file, nameSize) ||
        !PRIVATE_READ(_internal.file, extraFieldSize)) {
        return NO;
    }

    if (entry->fileHeader.nameSize != nameSize) {
        return NO;
    }

    seek = extraFieldSize + nameSize;
    if (0 != fseeko(_internal.file, seek, SEEK_CUR)) {
        return NO;
    }

    return YES;
}

- (BOOL)private_deflateWithProgressBlock:(nullable NOZProgressBlock)progressBlock usingBlock:(nonnull NOZUnzipByteRangeEnumerationBlock)block
{
    const size_t pageSize = NSPageSize();
    Byte uncompressedBuffer[pageSize];
    size_t uncompressedBufferSize = sizeof(uncompressedBuffer);
    Byte compressedBuffer[pageSize];
    size_t compressedBufferSize = sizeof(compressedBuffer);

    SInt64 uncompressedBytesConsumed = 0;
    const SInt64 totalUncompressedBytes = _currentUnzipping.entry->fileDescriptor.uncompressedSize;
    SInt64 uncompressedBytesConsumedThisPass = 1;
    BOOL stop = NO;
    SInt64 compressedBytesLeft = _currentUnzipping.entry->fileDescriptor.compressedSize;

    int zErr = Z_OK;
    while (!stop) {

        if ((size_t)compressedBytesLeft < compressedBufferSize) {
            compressedBufferSize = (size_t)compressedBytesLeft;
        }

        if (compressedBufferSize != fread(compressedBuffer, 1, compressedBufferSize, _internal.file)) {
            return NO;
        }
        compressedBytesLeft -= compressedBufferSize;

        _currentUnzipping.zStream.avail_in = (uInt)compressedBufferSize;
        _currentUnzipping.zStream.next_in = compressedBuffer;

        do {

            _currentUnzipping.zStream.avail_out = (uInt)uncompressedBufferSize;
            _currentUnzipping.zStream.next_out = uncompressedBuffer;

            zErr = inflate(&_currentUnzipping.zStream, Z_NO_FLUSH);

//            if (zErr == Z_STREAM_END) {
//                int inErr = inflate(&_currentUnzipping.zStream, Z_FULL_FLUSH);
//                (void)inErr;
//            }

            if (zErr == Z_OK || zErr == Z_STREAM_END) {
                uncompressedBytesConsumedThisPass = (SInt64)(uncompressedBufferSize - _currentUnzipping.zStream.avail_out);
                _currentUnzipping.crc32 = (UInt32)crc32(_currentUnzipping.crc32, uncompressedBuffer, (uInt)uncompressedBytesConsumedThisPass);

                uncompressedBytesConsumed += uncompressedBytesConsumedThisPass;
                block(uncompressedBuffer,
                      NSMakeRange((NSUInteger)(uncompressedBytesConsumed - uncompressedBytesConsumedThisPass), (NSUInteger)uncompressedBytesConsumedThisPass),
                      &stop);

                if (progressBlock) {
                    BOOL progressStop = NO;
                    progressBlock(totalUncompressedBytes, uncompressedBytesConsumed, uncompressedBytesConsumedThisPass, &progressStop);
                    if (progressStop) {
                        stop = YES;
                    }
                }

            }

            if (zErr != Z_OK) {
                stop = YES;
            }

        } while (_currentUnzipping.zStream.avail_out == 0 && !stop);
    };

    if (zErr != Z_STREAM_END) {
        return NO;
    }

    if (_currentUnzipping.crc32 != _currentUnzipping.entry->fileDescriptor.crc32) {
        return NO;
    }

    return YES;
}

@end

@implementation NOZCentralDirectory
{
    off_t _endOfCentralDirectoryRecordPosition;
    NOZEndOfCentralDirectoryRecordT _endOfCentralDirectoryRecord;

    NSArray *_records;
    off_t _lastCentralDirectoryRecordEndPosition; // exclusive
}

- (void)dealloc
{
}

- (nullable instancetype)init
{
    [self doesNotRecognizeSelector:_cmd];
    abort();
}

- (nonnull instancetype)initWithKnownFileSize:(SInt64)fileSize
{
    if (self = [super init]) {
        _totalUncompressedSize = fileSize;
    }
    return self;
}

- (NSUInteger)recordCount
{
    return _records.count;
}

@end

@implementation NOZCentralDirectory (Protected)

- (BOOL)readEndOfCentralDirectoryRecordAtPosition:(off_t)eocdPos inFile:(FILE*)file
{
    if (!file) {
        return NO;
    }

    if (fseeko(file, eocdPos, SEEK_SET) != 0) {
        return NO;
    }

    UInt32 signature = 0;
    if (!PRIVATE_READ(file, signature) || NOZMagicNumberEndOfCentralDirectoryRecord != signature) {
        return NO;
    }

    if (!PRIVATE_READ(file, _endOfCentralDirectoryRecord.diskNumber) ||
        !PRIVATE_READ(file, _endOfCentralDirectoryRecord.startDiskNumber) ||
        !PRIVATE_READ(file, _endOfCentralDirectoryRecord.recordCountForDisk) ||
        !PRIVATE_READ(file, _endOfCentralDirectoryRecord.totalRecordCount) ||
        !PRIVATE_READ(file, _endOfCentralDirectoryRecord.centralDirectorySize) ||
        !PRIVATE_READ(file, _endOfCentralDirectoryRecord.archiveStartToCentralDirectoryStartOffset) ||
        !PRIVATE_READ(file, _endOfCentralDirectoryRecord.commentSize)) {
        return NO;
    }

    if (_endOfCentralDirectoryRecord.commentSize) {
        unsigned char* commentBuffer = malloc(_endOfCentralDirectoryRecord.commentSize + 1);
        if (_endOfCentralDirectoryRecord.commentSize == fread(commentBuffer, 1, _endOfCentralDirectoryRecord.commentSize, file)) {
            commentBuffer[_endOfCentralDirectoryRecord.commentSize] = '\0';
            _globalComment = [[NSString alloc] initWithUTF8String:(const char *)commentBuffer];
        }
        free(commentBuffer);
    }

    _endOfCentralDirectoryRecordPosition = eocdPos;
    return YES;
}

- (BOOL)readCentralDirectoryEntriesWithFile:(FILE *)file
{
    if (!file || !_endOfCentralDirectoryRecordPosition) {
        return NO;
    }

    if (0 != fseeko(file, _endOfCentralDirectoryRecord.archiveStartToCentralDirectoryStartOffset, SEEK_SET)) {
        return NO;
    }

    NSMutableArray *records = [NSMutableArray arrayWithCapacity:_endOfCentralDirectoryRecord.totalRecordCount];
    while (_endOfCentralDirectoryRecordPosition > ftello(file)) {
        NOZCentralDirectoryRecord *record = [self readCentralDirectoryEntryAtCurrentPositionWithFile:file];
        if (record) {
            [records addObject:record];
        } else {
            break;
        }
    }

    _records = [records copy];
    return YES;
}

- (NOZCentralDirectoryRecord *)readCentralDirectoryEntryAtCurrentPositionWithFile:(FILE *)file
{
    UInt32 signature = 0;
    if (!PRIVATE_READ(file, signature) || signature != NOZMagicNumberCentralDirectoryFileRecord) {
        return nil;
    }

    NOZCentralDirectoryRecord *record = [[NOZCentralDirectoryRecord alloc] initWithOwner:self];
    NOZFileEntryT* entry = record.internalEntry;

    if (!PRIVATE_READ(file, entry->centralDirectoryRecord.versionMadeBy) ||
        !PRIVATE_READ(file, entry->centralDirectoryRecord.fileHeader->versionForExtraction) ||
        !PRIVATE_READ(file, entry->centralDirectoryRecord.fileHeader->bitFlag) ||
        !PRIVATE_READ(file, entry->centralDirectoryRecord.fileHeader->compressionMethod) ||
        !PRIVATE_READ(file, entry->centralDirectoryRecord.fileHeader->dosTime) ||
        !PRIVATE_READ(file, entry->centralDirectoryRecord.fileHeader->dosDate) ||
        !PRIVATE_READ(file, entry->centralDirectoryRecord.fileHeader->fileDescriptor->crc32) ||
        !PRIVATE_READ(file, entry->centralDirectoryRecord.fileHeader->fileDescriptor->compressedSize) ||
        !PRIVATE_READ(file, entry->centralDirectoryRecord.fileHeader->fileDescriptor->uncompressedSize) ||
        !PRIVATE_READ(file, entry->centralDirectoryRecord.fileHeader->nameSize) ||
        !PRIVATE_READ(file, entry->centralDirectoryRecord.fileHeader->extraFieldSize) ||
        !PRIVATE_READ(file, entry->centralDirectoryRecord.commentSize) ||
        !PRIVATE_READ(file, entry->centralDirectoryRecord.fileStartDiskNumber) ||
        !PRIVATE_READ(file, entry->centralDirectoryRecord.internalFileAttributes) ||
        !PRIVATE_READ(file, entry->centralDirectoryRecord.externalFileAttributes) ||
        !PRIVATE_READ(file, entry->centralDirectoryRecord.localFileHeaderOffsetFromStartOfDisk) ||
        entry->centralDirectoryRecord.fileHeader->nameSize == 0) {
        return nil;
    }

    entry->name = malloc(entry->centralDirectoryRecord.fileHeader->nameSize + 1);
    ((Byte*)entry->name)[entry->centralDirectoryRecord.fileHeader->nameSize] = '\0';
    entry->ownsName = YES;
    if (entry->centralDirectoryRecord.fileHeader->nameSize != fread((Byte*)entry->name, 1, entry->centralDirectoryRecord.fileHeader->nameSize, file)) {
        return nil;
    }

    if (entry->centralDirectoryRecord.fileHeader->extraFieldSize > 0) {
        if (0 != fseeko(file, entry->centralDirectoryRecord.fileHeader->extraFieldSize, SEEK_CUR)) {
            return nil;
        }
    }

    if (entry->centralDirectoryRecord.commentSize > 0) {
        entry->comment = malloc(entry->centralDirectoryRecord.commentSize + 1);
        ((Byte*)entry->comment)[entry->centralDirectoryRecord.commentSize] = '\0';
        entry->ownsComment = YES;
        if (entry->centralDirectoryRecord.commentSize != fread((Byte*)entry->comment, 1, entry->centralDirectoryRecord.commentSize, file)) {
            return nil;
        }
    }

    _totalUncompressedSize += record.uncompressedSize;
    _lastCentralDirectoryRecordEndPosition = ftello(file);
    return record;
}

- (NOZCentralDirectoryRecord *)recordAtIndex:(NSUInteger)index
{
    return [_records objectAtIndex:index];
}

- (NSUInteger)indexForRecordWithName:(NSString *)name
{
    __block NSUInteger index = NSNotFound;
    [_records enumerateObjectsUsingBlock:^(NOZCentralDirectoryRecord *record, NSUInteger idx, BOOL *stop) {
        if ([name isEqualToString:record.name]) {
            index = idx;
            *stop = YES;
        }
    }];
    return index;
}

- (NSArray *)internalRecords
{
    return _records;
}

- (BOOL)validateCentralDirectoryAndReturnError:(NSError **)error
{
    __block NOZErrorCode code = 0;
    __block NSDictionary *userInfo = nil;
    noz_defer(^{
        if (code && error) {
            *error = NOZError(code, userInfo);
        }
    });

    if (_endOfCentralDirectoryRecord.diskNumber != 0) {
        code = NOZErrorCodeUnzipMultipleDiskZipArchivesNotSupported;
        return NO;
    }

    if (0 == _records.count) {
        code = NOZErrorCodeUnzipCouldNotReadCentralDirectoryRecord;
        return NO;
    }

    if (_records.count != _endOfCentralDirectoryRecord.totalRecordCount) {
        code = NOZErrorCodeUnzipCentralDirectoryRecordCountsDoNotAlign;
        userInfo = @{ @"expectedCount" : @(_endOfCentralDirectoryRecord.totalRecordCount), @"actualCount" : @(_records.count) };
        return NO;
    }

    if (_endOfCentralDirectoryRecordPosition != _lastCentralDirectoryRecordEndPosition) {
        code = NOZErrorCodeUnzipCentralDirectoryRecordsDoNotCompleteWithEOCDRecord;
        return NO;
    }

    for (NOZCentralDirectoryRecord *record in _records) {
        code = [record validate];
        if (code) {
            return NO;
        }
    }

    return YES;
}

@end

@implementation NOZCentralDirectoryRecord
{
    NOZFileEntryT _entry;
    __unsafe_unretained NOZCentralDirectory *_owner;
}

- (void)dealloc
{
    NOZFileEntryClean(&_entry);
}

- (instancetype)initWithOwner:(NOZCentralDirectory *)cd
{
    if (self = [super init]) {
        NOZFileEntryInit(&_entry);
        _owner = cd;
    }
    return self;
}

- (instancetype)init
{
    [self doesNotRecognizeSelector:_cmd];
    abort();
}

- (NSString *)name
{
    return [[NSString alloc] initWithBytes:_entry.name length:_entry.fileHeader.nameSize encoding:NSUTF8StringEncoding];
}

- (NSString *)comment
{
    if (!_entry.comment) {
        return nil;
    }
    return [[NSString alloc] initWithBytes:_entry.comment length:_entry.centralDirectoryRecord.commentSize encoding:NSUTF8StringEncoding];
}

- (NOZCompressionLevel)compressionLevel
{
    UInt16 bitFlag = _entry.fileHeader.bitFlag;
    if (bitFlag & NOZFlagBitsSuperFastDeflate) {
        return NOZCompressionLevelMin;
    } else if (bitFlag & NOZFlagBitsFastDeflate) {
        return NOZCompressionLevelVeryLow;
    } else if (bitFlag & NOZFlagBitsMaxDeflate) {
        return NOZCompressionLevelMax;
    }
    return NOZCompressionLevelDefault;
}

- (NOZCompressionMethod)compressionMethod
{
    return _entry.fileHeader.compressionMethod;
}

- (SInt64)compressedSize
{
    return _entry.fileDescriptor.compressedSize;
}

- (SInt64)uncompressedSize
{
    return _entry.fileDescriptor.uncompressedSize;
}

- (id)copyWithZone:(NSZone *)zone
{
    NOZCentralDirectoryRecord *record = [[[self class] allocWithZone:zone] init];
    record->_entry.fileDescriptor = _entry.fileDescriptor;
    record->_entry.fileHeader = _entry.fileHeader;
    record->_entry.centralDirectoryRecord = _entry.centralDirectoryRecord;

    if (_entry.name) {
        record->_entry.name = malloc(_entry.fileHeader.nameSize + 1);
        memcpy((Byte *)record->_entry.name, _entry.name, _entry.fileHeader.nameSize + 1);
        record->_entry.ownsName = YES;
    }

    if (_entry.extraField) {
        record->_entry.extraField = malloc(_entry.fileHeader.extraFieldSize + 1);
        memcpy((Byte *)record->_entry.extraField, _entry.extraField, _entry.fileHeader.extraFieldSize + 1);
        record->_entry.ownsExtraField = YES;
    }

    if (_entry.comment) {
        record->_entry.comment = malloc(_entry.centralDirectoryRecord.commentSize + 1);
        memcpy((Byte *)record->_entry.comment, _entry.comment, _entry.centralDirectoryRecord.commentSize + 1);
        record->_entry.ownsComment = YES;
    }

    return record;
}

#pragma mark Internal

- (BOOL)isOwnedByCentralDirectory:(NOZCentralDirectory *)cd
{
    return (cd != nil) && (cd == _owner);
}

- (NOZFileEntryT *)internalEntry
{
    return &_entry;
}

- (BOOL)isZeroLength
{
    return (_entry.centralDirectoryRecord.fileHeader->fileDescriptor->compressedSize == 0);
}

- (BOOL)isMacOSXAttribute
{
    NSArray *components = [self.name pathComponents];
    if ([components containsObject:@"__MACOSX"]) {
        return YES;
    }
    return NO;
}

- (BOOL)isMacOSXDSStore
{
    if ([self.name.lastPathComponent isEqualToString:@".DS_Store"]) {
        return YES;
    }
    return NO;
}

- (NOZErrorCode)validate
{
    if (self.isZeroLength || self.isMacOSXAttribute || self.isMacOSXDSStore) {
        return 0;
    }

    if ((_entry.centralDirectoryRecord.fileHeader->versionForExtraction & 0x00ff) > (NOZVersionForExtraction & 0x00ff)) {
        return NOZErrorCodeUnzipUnsupportedRecordVersion;
    }
    if ((_entry.centralDirectoryRecord.fileHeader->bitFlag & 0b01)) {
        return NOZErrorCodeUnzipDecompressionEncryptionNotSupported;
    }
    if (_entry.centralDirectoryRecord.fileHeader->compressionMethod != Z_DEFLATED) {
        return NOZErrorCodeUnzipDecompressionMethodNotSupported;
    }

    return 0;
}

@end

static BOOL noz_fread_value(FILE *file, Byte* value, const UInt8 byteCount)
{
    for (size_t i = 0; i < byteCount; i++) {

#if __BIG_ENDIAN__
        size_t bytesRead = fread(value + (byteCount - 1 - i), 1, 1, file);
#else
        size_t bytesRead = fread(value + i, 1, 1, file);
#endif
        if (bytesRead != 1) {
            return NO;
        }
    }
    return YES;
}
