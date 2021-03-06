//
//  BundleDumpOperation.m
//  Clutch
//
//  Created by Anton Titkov on 11.02.15.
//
//

#import "BundleDumpOperation.h"
#import "Application.h"
#import "GBPrint.h"
#import "optool.h"
#import "NSData+Reading.h"
#import "Device.h"

#import "Dumper.h"

@import ObjectiveC.runtime;

@interface BundleDumpOperation ()
{
    ClutchBundle *_application;
    BOOL _executing, _finished;
    NSString *_binaryDumpPath;
}

+ (NSArray *)availableDumpers;

@end

@implementation BundleDumpOperation

- (instancetype)initWithBundle:(ClutchBundle *)application {
    self = [super init];
    if (self) {
        _executing = NO;
        _finished = NO;
        _application = application;
    }
    return self;
}

- (BOOL)isConcurrent {
    return YES;
}

- (BOOL)isExecuting {
    return _executing;
}

- (BOOL)isFinished {
    return _finished;
}

- (void)start {
    // Always check for cancellation before launching the task.
    if ([self isCancelled])
    {
        // Must move the operation to the finished state if it is canceled.
        [self willChangeValueForKey:@"isFinished"];
        _finished = YES;
        [self didChangeValueForKey:@"isFinished"];
        return;
    }
    
    self.completionBlock = ^{
        
    };
    
    // If the operation is not canceled, begin executing the task.
    [self willChangeValueForKey:@"isExecuting"];
    [NSThread detachNewThreadSelector:@selector(main) toTarget:self withObject:nil];
    _executing = YES;
    [self didChangeValueForKey:@"isExecuting"];
}



- (void)main {
    @try {
        
        NSFileManager *_fileManager = [NSFileManager defaultManager];
        
        Binary *originalBinary = _application.executable;
        
        _binaryDumpPath = [originalBinary.workingPath stringByAppendingPathComponent:originalBinary.binaryPath.lastPathComponent];
        
        [_fileManager createDirectoryAtPath:_binaryDumpPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        
        //if (![_application isKindOfClass:[Framework class]])
        [_fileManager copyItemAtPath:originalBinary.binaryPath toPath:_binaryDumpPath error:nil];
                
        NSFileHandle *tmpHandle = [[NSFileHandle alloc]initWithFileDescriptor:fileno(fopen(originalBinary.binaryPath.UTF8String, "r+"))];
        
        NSData *headersData = tmpHandle.availableData;
        
        [tmpHandle closeFile];
        
        if (!headersData) {
            gbprintln(@"Failed to extract headers info from binary %@.",originalBinary);
            [self completeOperation];
            return;
        }
        
        thin_header headers[4];
        uint32_t numHeaders = 0;
        
        headersFromBinary(headers, headersData, &numHeaders);
        
        if (numHeaders == 0) {
            gbprintln(@"No compatible architecture found");
        }
        
        BOOL isFAT = numHeaders > 1;
        
        uint32_t dumpCount = 0;
        
        NSMutableArray *_headersToStrip = [NSMutableArray new];
        
        NSArray *dumpers = [_application isKindOfClass:[Framework class]] ? [self.class availableFrameworkDumpers]: [self.class availableDumpers];
        
        for (uint32_t i = 0; i < numHeaders; i++) {
            
            thin_header macho = headers[i];
            Dumper<BinaryDumpProtocol> *_dumper;
            for (Class dumperClass in dumpers) {
                _dumper = [[dumperClass alloc]initWithHeader:macho originalBinary:originalBinary];
                
                if ([_dumper compatibilityMode] == ArchCompatibilityNotCompatible) {
                    NSLog(@"%@ cannot dump binary %@ with arch %@",_dumper,originalBinary,[Dumper readableArchFromHeader:macho]);
                    _dumper = nil;
                }else
                    break;
            }
            
            if (!_dumper) {
                NSLog(@"Couldn't find compatible dumper for binary %@ with arch %@. Will have to \"strip\".",originalBinary,[Dumper readableArchFromHeader:macho]);
                
                NSValue* archValue = [NSValue value:&macho withObjCType:@encode(thin_header)];
                [_headersToStrip addObject:archValue];
                continue;
            }
            
            // _dumper.shouldDisableASLR = YES; // yoyoyo
            
            NSLog(@"Found compatible dumper %@ for binary %@ with arch %@",_dumper,originalBinary,[Dumper readableArchFromHeader:macho]);
            
            NSFileHandle *_handle = [[NSFileHandle alloc]initWithFileDescriptor:fileno(fopen(originalBinary.binaryPath.UTF8String, "r+"))];
            
            _dumper.originalFileHandle = _handle;
            
            BOOL result = [_dumper dumpBinary];
            
            if (result) {
                dumpCount++;
                gbprintln(@"Finished dumping binary %@ %@ with result: %i",originalBinary,[Dumper readableArchFromHeader:macho],result);
            }else {
                gbprintln(@"Failed to dump binary %@ with arch %@",originalBinary,[Dumper readableArchFromHeader:macho]);
            }
            
            [_handle closeFile];
        }
        
        if (!dumpCount) {
            gbprintln(@"Failed to dump binary %@",originalBinary);
            [self completeOperation];
            return;
        }
        
        
#pragma mark "stripping" headers in FAT binary
        if (isFAT) {
            NSFileHandle *_dumpHandle = [[NSFileHandle alloc]initWithFileDescriptor:fileno(fopen(_binaryDumpPath.UTF8String, "r+"))];
            
            uint32_t magic = [_dumpHandle intAtOffset:0];
            bool shouldSwap = magic == FAT_CIGAM;
#define SWAP(NUM) (shouldSwap ? CFSwapInt32(NUM) : NUM)
            
            NSData *buffer = _dumpHandle.availableData;
            
            struct fat_header fat = *(struct fat_header *)buffer.bytes;
            int offset = sizeof(struct fat_header);
            
            for (NSValue *valueWithArch in _headersToStrip) {
                thin_header stripArch;
                [valueWithArch getValue:&stripArch];
                
                for (int i = 0; i < SWAP(fat.nfat_arch); i++) {
                    struct fat_arch arch;
                    arch = *(struct fat_arch *)([buffer bytes] + offset);
                    
                    if (((SWAP(arch.cputype) == stripArch.header.cputype) && (SWAP(arch.cpusubtype) == stripArch.header.cpusubtype))) {
                        
                        if (SWAP(arch.cputype) == CPU_TYPE_ARM) {
                            switch (SWAP(arch.cpusubtype)) {
                                case CPU_SUBTYPE_ARM_V6:
                                    arch.cputype = SWAP(CPU_TYPE_I386);
                                    arch.cpusubtype = SWAP(CPU_SUBTYPE_PENTIUM_3_XEON);
                                    break;
                                case CPU_SUBTYPE_ARM_V7:
                                    arch.cputype = SWAP(CPU_TYPE_I386);
                                    arch.cpusubtype = SWAP(CPU_SUBTYPE_PENTIUM_4);
                                    break;
                                case CPU_SUBTYPE_ARM_V7S:
                                    arch.cputype = SWAP(CPU_TYPE_I386);
                                    arch.cpusubtype = SWAP(CPU_SUBTYPE_ITANIUM);
                                    break;
                                case CPU_SUBTYPE_ARM_V7K: // Apple Watch FTW
                                    arch.cputype = SWAP(CPU_TYPE_I386);
                                    arch.cpusubtype = SWAP(CPU_SUBTYPE_XEON);
                                    break;
                            }
                        }else {
                            
                            switch (SWAP(arch.cpusubtype)) {
                                case CPU_SUBTYPE_ARM64_ALL:
                                    arch.cputype = SWAP(CPU_TYPE_X86_64);
                                    arch.cpusubtype = SWAP(CPU_SUBTYPE_X86_64_ALL);
                                    break;
                                case CPU_SUBTYPE_ARM64_V8:
                                    arch.cputype = SWAP(CPU_TYPE_X86_64);
                                    arch.cpusubtype = SWAP(CPU_SUBTYPE_X86_64_H);
                                    break;
                            }
                            
                        }
                        
                        stripArch.header.cputype = SWAP(arch.cputype);
                        stripArch.header.cpusubtype = SWAP(arch.cpusubtype);
                        
                        [_dumpHandle replaceBytesInRange:NSMakeRange(offset, sizeof(struct fat_arch)) withBytes:&arch];
                        [_dumpHandle replaceBytesInRange:NSMakeRange(stripArch.offset, sizeof(stripArch.header)) withBytes:&stripArch.header];

                    }
                    
                    offset += sizeof(struct fat_arch);
                }

            }
            
            [_dumpHandle closeFile];
        }
        
        
#pragma mark checking if everything's fine
        if (dumpCount == (numHeaders-_headersToStrip.count))
        {
            NSString *_localPath = [originalBinary.binaryPath stringByReplacingOccurrencesOfString:_application.bundleContainerURL.path withString:@""];
            
            _localPath = [_application.zipPrefix stringByAppendingPathComponent:_localPath];
            
            [@{_binaryDumpPath:_localPath} writeToFile:[originalBinary.workingPath stringByAppendingPathComponent:@"filesToAdd.plist"] atomically:YES];
        }
        
        // Do the main work of the operation here.
        [self completeOperation];
    }
    @catch(...) {
        // Do not rethrow exceptions.
    }
}

- (void)completeOperation {
    [self willChangeValueForKey:@"isFinished"];
    [self willChangeValueForKey:@"isExecuting"];
    _executing = NO;
    _finished = YES;
    [self didChangeValueForKey:@"isExecuting"];
    [self didChangeValueForKey:@"isFinished"];
}

+ (NSArray *)availableDumpers
{
    return @[NSClassFromString(@"ARM64Dumper"),NSClassFromString(@"ARMDumper")];
}

+ (NSArray *)availableFrameworkDumpers
{
    return @[NSClassFromString(@"FrameworkDumper"),NSClassFromString(@"Framework64Dumper")];
}


@end
