#import "RuntimeMethodDumper.h"
#import <objc/runtime.h>

@implementation RuntimeMethodDumper

+ (NSString *)backdropLayerClassName {
    return [@[@"CA", @"Backdrop", @"Layer"] componentsJoinedByString:@""];
}

+ (void)dumpMethodsForCABackdropLayer {
    Class cls = NSClassFromString([self backdropLayerClassName]);
    if (!cls) {
        NSLog(@"[RuntimeMethodDumper] CABackdropLayer class not found");
        return;
    }

    NSLog(@"=== %@ Methods ===", [self backdropLayerClassName]);

    // Instance methods
    NSLog(@"--- Instance Methods ---");
    unsigned int instanceMethodCount = 0;
    Method *instanceMethods = class_copyMethodList(cls, &instanceMethodCount);

    for (unsigned int i = 0; i < instanceMethodCount; i++) {
        Method method = instanceMethods[i];
        SEL selector = method_getName(method);
        const char *typeEncoding = method_getTypeEncoding(method);
        NSLog(@"- %@ [%s]", NSStringFromSelector(selector), typeEncoding ?: "");
    }
    free(instanceMethods);

    NSLog(@"Total instance methods: %u", instanceMethodCount);

    // Class methods
    NSLog(@"--- Class Methods ---");
    Class metaClass = object_getClass(cls);
    unsigned int classMethodCount = 0;
    Method *classMethods = class_copyMethodList(metaClass, &classMethodCount);

    for (unsigned int i = 0; i < classMethodCount; i++) {
        Method method = classMethods[i];
        SEL selector = method_getName(method);
        const char *typeEncoding = method_getTypeEncoding(method);
        NSLog(@"+ %@ [%s]", NSStringFromSelector(selector), typeEncoding ?: "");
    }
    free(classMethods);

    NSLog(@"Total class methods: %u", classMethodCount);
    NSLog(@"=== End %@ Methods ===", [self backdropLayerClassName]);
}

+ (NSArray<NSString *> *)methodListForCABackdropLayer {
    NSMutableArray<NSString *> *result = [NSMutableArray array];

    Class cls = NSClassFromString([self backdropLayerClassName]);
    if (!cls) {
        return result;
    }

    // Instance methods
    unsigned int instanceMethodCount = 0;
    Method *instanceMethods = class_copyMethodList(cls, &instanceMethodCount);

    for (unsigned int i = 0; i < instanceMethodCount; i++) {
        Method method = instanceMethods[i];
        SEL selector = method_getName(method);
        [result addObject:[NSString stringWithFormat:@"- %@", NSStringFromSelector(selector)]];
    }
    free(instanceMethods);

    // Class methods
    Class metaClass = object_getClass(cls);
    unsigned int classMethodCount = 0;
    Method *classMethods = class_copyMethodList(metaClass, &classMethodCount);

    for (unsigned int i = 0; i < classMethodCount; i++) {
        Method method = classMethods[i];
        SEL selector = method_getName(method);
        [result addObject:[NSString stringWithFormat:@"+ %@", NSStringFromSelector(selector)]];
    }
    free(classMethods);

    return result;
}

@end
