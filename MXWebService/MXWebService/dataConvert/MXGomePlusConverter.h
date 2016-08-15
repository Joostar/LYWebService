//
//  MXJsonConverter.h
//  MXEngine
//
//  Created by lly on 16/6/13.
//  Copyright © 2016年 lly. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "MXDataConverterFactory.h"

@interface MXGomePlusConverter : NSObject<MXDataConverter>

- (id)convertJSONObject:(id)jsonObject toObjectOfClass:(Class)cls error:(NSError**)error;

@end