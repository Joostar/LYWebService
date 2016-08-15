//
//  MXMethodDescription.m
//  MXEngine
//
//  Created by lly on 16/6/13.
//  Copyright © 2016年 lly. All rights reserved.
//

#import "MXMethodDescription.h"
#import "NSInvocation+MXUtils.h"
#import "MXTypeEncoding.h"
#import "MXDataConverterFactory.h"
#import "MXParameterizeResult.h"

static NSString* const BODY_ANNOTATION_NAME = @"Body";
static NSString* const HEADERS_ANNOTATION_NAME = @"Headers";
static NSString* const FORM_URL_ENCODED_ANNOTATION_NAME = @"FormUrlEncoded";

@implementation MXMethodDescription

+ (NSArray*)httpMethodNames
{
    static NSArray* names = nil;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        names = @[
                  @"GET",
                  @"POST",
                  @"DELETE",
                  @"PUT",
                  @"HEAD",
                  @"PATCH"
                  ];
    });
    
    return names;
}

- (instancetype)initWithDictionary:(NSDictionary*)dictionary
{
    self = [super init];
    
    if (self) {
        _parameterNames = dictionary[@"parameterNames"];
        _resultType = dictionary[@"resultType"];
        _annotations = dictionary[@"annotations"];
        _taskType = dictionary[@"taskType"];
    }
    
    return self;
}

- (NSString*)description
{
    return [NSString stringWithFormat:@"<%@: %p, resultType: %@, taskType:%@, params:%@, annotations:%@>",
            NSStringFromClass([self class]),
            self, self.resultType, self.taskType,
            self.parameterNames,
            self.annotations];
}

- (NSString*)httpMethod
{
    for (NSString* method in [self.class httpMethodNames]) {
        if (self.annotations[method]) {
            return method;
        }
    }
    
    NSAssert(NO, @"Could not determine HTTP method");
    return nil;
}

- (Class)taskClass
{
    NSString* taskString = [self.taskType stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    NSArray* split = [taskString componentsSeparatedByString:@"*"];
    NSString* taskClassName = [[split firstObject] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return NSClassFromString(taskClassName);
}

- (Class)resultSubtype
{
    NSError* error = nil;
    NSRegularExpression* regex = [NSRegularExpression regularExpressionWithPattern:@"<[\\s]*([a-zA-Z0-9_]+)[\\s]*\\**[\\s]*>" options:0 error:&error];
    
    NSTextCheckingResult* match = [regex firstMatchInString:self.resultType options:0 range:NSMakeRange(0, self.resultType.length)];
    
    if (match && match.range.location != NSNotFound) {
        NSRange subtypeRange = [match rangeAtIndex:1];
        NSString* subtypeName = [self.resultType substringWithRange:subtypeRange];
        return NSClassFromString(subtypeName);
    } else {
        return nil;
    }
}

- (Class)resultConversionClass
{
    if ([self.resultType hasPrefix:@"NSArray"]) {
        return [self resultSubtype];
    } else {
        NSString* resultString = [self.resultType stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        NSArray* split = [resultString componentsSeparatedByString:@"*"];
        NSString* resultClassName = [[split firstObject] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        return NSClassFromString(resultClassName);
    }
}

- (BOOL)isFormURLEncoded
{
    NSNumber* isEncoded = self.annotations[FORM_URL_ENCODED_ANNOTATION_NAME];
    
    return isEncoded.boolValue;
}

- (NSString*)stringValueForParameterAtIndex:(NSUInteger)index
                             withInvocation:(NSInvocation*)invocation
                                  converter:(id<MXDataConverter>)converter
                                      error:(NSError**)error
{
    NSString* paramValue = nil;
    MXTypeEncoding* encoding = [invocation typeEncodingForParameterAtIndex:index];
    
    if (encoding.encodingClass == MXObjectTypeEncodingClass) {
        id obj = [invocation objectValueForParameterAtIndex:index];
        
        if ([obj isKindOfClass:[NSString class]]) {
            paramValue = obj;
        } else if ([obj isKindOfClass:[NSNumber class]]) {
            paramValue = [obj stringValue];
        } else if ([converter respondsToSelector:@selector(convertObjectToString:error:)]) {
            paramValue = [converter convertObjectToString:obj error:error];
        } else {
            NSAssert(NO, @"Could not convert parameter at index: %lu", (unsigned long)index);
        }
    } else {
        paramValue = [invocation stringValueForParameterAtIndex:index];
    }
    
    return paramValue;
}

- (MXParameterizeResult<NSDictionary*>*)parameterizedHeadersForInvocation:(NSInvocation*)invocation
                                                            withConverter:(id<MXDataConverter>)converter
                                                                    error:(NSError**)error
{
    NSDictionary* headers = self.annotations[HEADERS_ANNOTATION_NAME];
    NSMutableDictionary* result = [[NSMutableDictionary alloc] init];
    NSMutableSet* consumedParameters = [[NSMutableSet alloc] init];
    
    for (NSString* key in headers) {
        NSString* headerValue = headers[key];
        MXParameterizeResult<NSString*>* valueResult = [self parameterizedString:headerValue
                                                                   forInvocation:invocation
                                                                   withConverter:converter
                                                                           error:error];
        result[key] = valueResult.result;
        [consumedParameters unionSet:valueResult.consumedParameters];
    }
    
    return [[MXParameterizeResult alloc] initWithResult:result.copy consumedParameters:consumedParameters];
}

- (MXParameterizeResult<NSString*>*)parameterizedPathForInvocation:(NSInvocation*)invocation
                                                     withConverter:(id<MXDataConverter>)converter
                                                             error:(NSError**)error
{
    NSString* path = self.annotations[self.httpMethod];
    return [self parameterizedString:path
                       forInvocation:invocation withConverter:converter
                               error:error];
}

- (MXParameterizeResult<NSString*>*)parameterizedString:(NSString*)string
                                          forInvocation:(NSInvocation*)invocation
                                          withConverter:(id<MXDataConverter>)converter
                                                  error:(NSError**)error
{
    NSMutableSet* consumedParameters = [[NSMutableSet alloc] init];
    NSMutableString* paramedString = string.mutableCopy;
    NSRegularExpression* regex = [NSRegularExpression regularExpressionWithPattern:@"\\{([a-zA-Z0-9_]+)\\}"
                                                                           options:0
                                                                             error:error];
    
    if (error && *error) {
        return nil;
    }
    
    NSArray *matches = [regex matchesInString:string
                                      options:0
                                        range:NSMakeRange(0, [string length])];
    
    for (NSInteger i = matches.count - 1; i >= 0; i--) {
        NSTextCheckingResult* match = matches[i];
        NSRange nameRange = [match rangeAtIndex:1];
        NSString* paramName = [string substringWithRange:nameRange];
        NSUInteger paramIdx = [self.parameterNames indexOfObject:paramName];
        
        // TODO: this should probably be allowed, in case some URL randomly contains "{not_a_param}"
        NSAssert(paramIdx != NSNotFound, @"Unknown substitution variable in path: %@", paramName);
        
        NSString* paramValue = [self stringValueForParameterAtIndex:paramIdx
                                                     withInvocation:invocation
                                                          converter:converter
                                                              error:error];
        
        if (error && *error) {
            return nil;
        }
        
        paramValue = [paramValue stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
        
        [paramedString replaceCharactersInRange:match.range withString:paramValue];
        [consumedParameters addObject:paramName];
    }
    
    return [[MXParameterizeResult alloc] initWithResult:paramedString.copy
                                     consumedParameters:consumedParameters];
}

- (MXParameterizeResult*)bodyForInvocation:(NSInvocation*)invocation
                             withConverter:(id<MXDataConverter>)converter
                                     error:(NSError**)error
{
    NSString* bodyParamName = self.annotations[BODY_ANNOTATION_NAME];
    id result = nil;
    
    if (bodyParamName.length > 0) {
        NSUInteger paramIdx = [self.parameterNames indexOfObject:bodyParamName];
        NSAssert(paramIdx != NSNotFound, @"Unknown parameter for body: %@", bodyParamName);
        
        MXTypeEncoding* encoding = [invocation typeEncodingForParameterAtIndex:paramIdx];
        
        if (encoding.encodingClass == MXObjectTypeEncodingClass) {
            id obj = [invocation objectValueForParameterAtIndex:paramIdx];
            
            if ([obj isKindOfClass:[NSInputStream class]]
                || [obj isKindOfClass:[NSURL class]]
                || [obj isKindOfClass:[NSData class]])
            {
                result = obj;
            } else if ([obj isKindOfClass:[NSString class]]) {
                NSString* string = obj;
                result = [string dataUsingEncoding:NSUTF8StringEncoding];
            } else if ([obj isKindOfClass:[NSNumber class]]) {
                NSNumber* number = obj;
                result = [[number stringValue] dataUsingEncoding:NSUTF8StringEncoding];
            } else {
                result = [converter convertObjectToData:obj error:error];
                
                if (error && *error) {
                    return nil;
                }
            }
        } else {
            NSString* stringValue = [invocation stringValueForParameterAtIndex:paramIdx];
            result = [stringValue dataUsingEncoding:NSUTF8StringEncoding];
        }
        
        return [[MXParameterizeResult alloc] initWithResult:result
                                         consumedParameters:[NSSet setWithObject:bodyParamName]];
    } else {
        return [[MXParameterizeResult alloc] initWithResult:nil
                                         consumedParameters:[NSSet set]];
    }
}


@end
