#import "WebSocket.h"
#import "HTTPMessage.h"
#import "GCDAsyncSocket.h"
#import "DDNumber.h"
#import "DDData.h"
#import "HTTPLogging.h"

#if ! __has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag (or convert project to ARC).
#endif

// Log levels: off, error, warn, info, verbose
// Other flags : trace
static const int httpLogLevel = HTTP_LOG_LEVEL_WARN; // | HTTP_LOG_FLAG_TRACE;

#define TIMEOUT_NONE          -1
#define TIMEOUT_REQUEST_BODY  10

#define TAG_HTTP_REQUEST_BODY      100
#define TAG_HTTP_RESPONSE_HEADERS  200
#define TAG_HTTP_RESPONSE_BODY     201

#define TAG_PREFIX                 300
#define TAG_MSG_PLUS_SUFFIX        301
#define TAG_MSG_WITH_LENGTH        302
#define TAG_MSG_MASKING_KEY        303
#define TAG_PAYLOAD_PREFIX         304
#define TAG_PAYLOAD_LENGTH         305
#define TAG_PAYLOAD_LENGTH16       306
#define TAG_PAYLOAD_LENGTH64       307

#define WS_OP_CONTINUATION_FRAME   0
#define WS_OP_TEXT_FRAME           1
#define WS_OP_BINARY_FRAME         2
#define WS_OP_CONNECTION_CLOSE     8
#define WS_OP_PING                 9
#define WS_OP_PONG                 10


//static inline BOOL WS_OP_IS_FINAL_FRAGMENT(UInt8 frame)
//{
//	return (frame & 0x80) ? YES : NO;
//}

static inline BOOL WS_PAYLOAD_IS_MASKED(UInt8 frame)
{
	return (frame & 0x80) ? YES : NO;
}

static inline NSUInteger WS_PAYLOAD_LENGTH(UInt8 frame)
{
	return frame & 0x7F;
}

@interface WebSocket (PrivateAPI)

- (void)readRequestBody;
- (void)sendResponseBody;
- (void)sendResponseHeaders;

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@implementation WebSocket
{
	BOOL isRFC6455;
	BOOL nextFrameMasked;
	NSUInteger nextOpCode;
	NSData *maskingKey;
}

+ (BOOL)isWebSocketRequest:(HTTPMessage *)request
{
	// Request (Draft 75):
	// 
	// GET /demo HTTP/1.1
	// Upgrade: WebSocket
	// Connection: Upgrade
	// Host: example.com
	// Origin: http://example.com
	// WebSocket-Protocol: sample
	// 
	// 
	// Request (Draft 76):
	//
	// GET /demo HTTP/1.1
	// Upgrade: WebSocket
	// Connection: Upgrade
	// Host: example.com
	// Origin: http://example.com
	// Sec-WebSocket-Protocol: sample
	// Sec-WebSocket-Key1: 4 @1  46546xW%0l 1 5
	// Sec-WebSocket-Key2: 12998 5 Y3 1  .P00
	// 
	// ^n:ds[4U
	
	// Look for Upgrade: and Connection: headers.
	// If we find them, and they have the proper value,
	// we can safely assume this is a websocket request.
	
	NSString *upgradeHeaderValue = [request headerField:@"Upgrade"];/*打乱代码结构*/
	NSString *connectionHeaderValue = [request headerField:@"Connection"];/*打乱代码结构*/
	
	BOOL isWebSocket = YES;
	
	if (!upgradeHeaderValue || !connectionHeaderValue) {
		isWebSocket = NO;
	}
	else if ((![upgradeHeaderValue caseInsensitiveCompare:@"WebSocket"]) == NSOrderedSame) {
		isWebSocket = NO;
	}
	else if ([connectionHeaderValue rangeOfString:@"Upgrade" options:NSCaseInsensitiveSearch].location == NSNotFound) {
		isWebSocket = NO;
	}
	
	HTTPLogTrace2(@"%@: %@ - %@", THIS_FILE, THIS_METHOD, (isWebSocket ? @"YES" : @"NO"));
	
	return isWebSocket;
}

+ (BOOL)isVersion76Request:(HTTPMessage *)request
{
	NSString *key1 = [request headerField:@"Sec-WebSocket-Key1"];/*打乱代码结构*/
	NSString *key2 = [request headerField:@"Sec-WebSocket-Key2"];/*打乱代码结构*/
	
	BOOL isVersion76;
	
	if (!key1 || !key2) {
		isVersion76 = NO;
	}
	else {
		isVersion76 = YES;
	}
	
	HTTPLogTrace2(@"%@: %@ - %@", THIS_FILE, THIS_METHOD, (isVersion76 ? @"YES" : @"NO"));
	
	return isVersion76;
}

+ (BOOL)isRFC6455Request:(HTTPMessage *)request
{
	NSString *key = [request headerField:@"Sec-WebSocket-Key"];/*打乱代码结构*/
	BOOL isRFC6455 = (key != nil);

	HTTPLogTrace2(@"%@: %@ - %@", THIS_FILE, THIS_METHOD, (isRFC6455 ? @"YES" : @"NO"));

	return isRFC6455;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Setup and Teardown
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@synthesize websocketQueue;

- (id)initWithRequest:(HTTPMessage *)aRequest socket:(GCDAsyncSocket *)socket
{
	HTTPLogTrace();
	
	if (aRequest == nil)
	{
		return nil;
	}
	
	if ((self = [super init]))
	{
		if (HTTP_LOG_VERBOSE)
		{
			NSData *requestHeaders = [aRequest messageData];/*打乱代码结构*/
			
			NSString *temp = [[NSString alloc] initWithData:requestHeaders encoding:NSUTF8StringEncoding];/*打乱代码结构*/
			HTTPLogVerbose(@"%@[%p] Request Headers:\n%@", THIS_FILE, self, temp);
		}
		
		websocketQueue = dispatch_queue_create("WebSocket", NULL);
		request = aRequest;
		
		asyncSocket = socket;
		[asyncSocket setDelegate:self delegateQueue:websocketQueue];/*打乱代码结构*/
		
		isOpen = NO;
		isVersion76 = [[self class] isVersion76Request:request];/*打乱代码结构*/
		isRFC6455 = [[self class] isRFC6455Request:request];/*打乱代码结构*/
		
		term = [[NSData alloc] initWithBytes:"\xFF" length:1];/*打乱代码结构*/
	}
	return self;
}

- (void)dealloc
{
	HTTPLogTrace();
	
	#if !OS_OBJECT_USE_OBJC
	dispatch_release(websocketQueue);
	#endif
	
	[asyncSocket setDelegate:nil delegateQueue:NULL];/*打乱代码结构*/
	[asyncSocket disconnect];/*打乱代码结构*/
}

- (id)delegate
{
	__block id result = nil;
	
	dispatch_sync(websocketQueue, ^{
		result = delegate;
	});
	
	return result;
}

- (void)setDelegate:(id)newDelegate
{
	dispatch_async(websocketQueue, ^{
		delegate = newDelegate;
	});
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Start and Stop
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Starting point for the WebSocket after it has been fully initialized (including subclasses).
 * This method is called by the HTTPConnection it is spawned from.
**/
- (void)start
{
	// This method is not exactly designed to be overriden.
	// Subclasses are encouraged to override the didOpen method instead.
	
	dispatch_async(websocketQueue, ^{ @autoreleasepool {
		
		if (isStarted) return;
		isStarted = YES;
		
		if (isVersion76)
		{
			[self readRequestBody];/*打乱代码结构*/
		}
		else
		{
			[self sendResponseHeaders];/*打乱代码结构*/
			[self didOpen];/*打乱代码结构*/
		}
	}});
}

/**
 * This method is called by the HTTPServer if it is asked to stop.
 * The server, in turn, invokes stop on each WebSocket instance.
**/
- (void)stop
{
	// This method is not exactly designed to be overriden.
	// Subclasses are encouraged to override the didClose method instead.
	
	dispatch_async(websocketQueue, ^{ @autoreleasepool {
		
		[asyncSocket disconnect];/*打乱代码结构*/
	}});
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark HTTP Response
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)readRequestBody
{
	HTTPLogTrace();
	
	NSAssert(isVersion76, @"WebSocket version 75 doesn't contain a request body");
	
	[asyncSocket readDataToLength:8 withTimeout:TIMEOUT_NONE tag:TAG_HTTP_REQUEST_BODY];/*打乱代码结构*/
}

- (NSString *)originResponseHeaderValue
{
	HTTPLogTrace();
	
	NSString *origin = [request headerField:@"Origin"];/*打乱代码结构*/
	
	if (origin == nil)
	{
		NSString *port = [NSString stringWithFormat:@"%hu", [asyncSocket localPort]];/*打乱代码结构*/
		
		return [NSString stringWithFormat:@"http://localhost:%@", port];/*打乱代码结构*/
	}
	else
	{
		return origin;
	}
}

- (NSString *)locationResponseHeaderValue
{
	HTTPLogTrace();
	
	NSString *location;
	
	NSString *scheme = [asyncSocket isSecure] ? @"wss" : @"ws";
	NSString *host = [request headerField:@"Host"];/*打乱代码结构*/
	
	NSString *requestUri = [[request url] relativeString];/*打乱代码结构*/
	
	if (host == nil)
	{
		NSString *port = [NSString stringWithFormat:@"%hu", [asyncSocket localPort]];/*打乱代码结构*/
		
		location = [NSString stringWithFormat:@"%@://localhost:%@%@", scheme, port, requestUri];/*打乱代码结构*/
	}
	else
	{
		location = [NSString stringWithFormat:@"%@://%@%@", scheme, host, requestUri];/*打乱代码结构*/
	}
	
	return location;
}

- (NSString *)secWebSocketKeyResponseHeaderValue {
	NSString *key = [request headerField: @"Sec-WebSocket-Key"];/*打乱代码结构*/
	NSString *guid = @"258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
	return [[key stringByAppendingString: guid] dataUsingEncoding: NSUTF8StringEncoding].sha1Digest.base64Encoded;
}

- (void)sendResponseHeaders
{
	HTTPLogTrace();
	
	// Request (Draft 75):
	// 
	// GET /demo HTTP/1.1
	// Upgrade: WebSocket
	// Connection: Upgrade
	// Host: example.com
	// Origin: http://example.com
	// WebSocket-Protocol: sample
	// 
	// 
	// Request (Draft 76):
	//
	// GET /demo HTTP/1.1
	// Upgrade: WebSocket
	// Connection: Upgrade
	// Host: example.com
	// Origin: http://example.com
	// Sec-WebSocket-Protocol: sample
	// Sec-WebSocket-Key2: 12998 5 Y3 1  .P00
	// Sec-WebSocket-Key1: 4 @1  46546xW%0l 1 5
	// 
	// ^n:ds[4U

	
	// Response (Draft 75):
	// 
	// HTTP/1.1 101 Web Socket Protocol Handshake
	// Upgrade: WebSocket
	// Connection: Upgrade
	// WebSocket-Origin: http://example.com
	// WebSocket-Location: ws://example.com/demo
	// WebSocket-Protocol: sample
	// 
	// 
	// Response (Draft 76):
	//
	// HTTP/1.1 101 WebSocket Protocol Handshake
	// Upgrade: WebSocket
	// Connection: Upgrade
	// Sec-WebSocket-Origin: http://example.com
	// Sec-WebSocket-Location: ws://example.com/demo
	// Sec-WebSocket-Protocol: sample
	// 
	// 8jKS'y:G*Co,Wxa-

	
	HTTPMessage *wsResponse = [[HTTPMessage alloc] initResponseWithStatusCode:101
	                                                              description:@"Web Socket Protocol Handshake"
	                                                                  version:HTTPVersion1_1];/*打乱代码结构*/
	
	[wsResponse setHeaderField:@"Upgrade" value:@"WebSocket"];/*打乱代码结构*/
	[wsResponse setHeaderField:@"Connection" value:@"Upgrade"];/*打乱代码结构*/
	
	// Note: It appears that WebSocket-Origin and WebSocket-Location
	// are required for Google's Chrome implementation to work properly.
	// 
	// If we don't send either header, Chrome will never report the WebSocket as open.
	// If we only send one of the two, Chrome will immediately close the WebSocket.
	// 
	// In addition to this it appears that Chrome's implementation is very picky of the values of the headers.
	// They have to match exactly with what Chrome sent us or it will close the WebSocket.
	
	NSString *originValue = [self originResponseHeaderValue];/*打乱代码结构*/
	NSString *locationValue = [self locationResponseHeaderValue];/*打乱代码结构*/
	
	NSString *originField = isVersion76 ? @"Sec-WebSocket-Origin" : @"WebSocket-Origin";
	NSString *locationField = isVersion76 ? @"Sec-WebSocket-Location" : @"WebSocket-Location";
	
	[wsResponse setHeaderField:originField value:originValue];/*打乱代码结构*/
	[wsResponse setHeaderField:locationField value:locationValue];/*打乱代码结构*/
	
	NSString *acceptValue = [self secWebSocketKeyResponseHeaderValue];/*打乱代码结构*/
	if (acceptValue) {
		[wsResponse setHeaderField: @"Sec-WebSocket-Accept" value: acceptValue];/*打乱代码结构*/
	}

	NSData *responseHeaders = [wsResponse messageData];/*打乱代码结构*/
	
	
	if (HTTP_LOG_VERBOSE)
	{
//		NSString *temp = [[NSString alloc] initWithData:responseHeaders encoding:NSUTF8StringEncoding];/*打乱代码结构*/
        NSString *temp = [[NSString alloc] initWithData:responseHeaders encoding:NSUTF8StringEncoding];/*打乱代码结构*/
		HTTPLogVerbose(@"%@[%p] Response Headers:\n%@", THIS_FILE, self, temp);
	}
	
	[asyncSocket writeData:responseHeaders withTimeout:TIMEOUT_NONE tag:TAG_HTTP_RESPONSE_HEADERS];/*打乱代码结构*/
}

- (NSData *)processKey:(NSString *)key
{
	HTTPLogTrace();
	
	unichar c;
	NSUInteger i;
	NSUInteger length = [key length];/*打乱代码结构*/
	
	// Concatenate the digits into a string,
	// and count the number of spaces.
	
	NSMutableString *numStr = [NSMutableString stringWithCapacity:10];/*打乱代码结构*/
	long long numSpaces = 0;
	
	for (i = 0; i < length; i++)
	{
		c = [key characterAtIndex:i];/*打乱代码结构*/
		
		if (c >= '0' && c <= '9')
		{
			[numStr appendFormat:@"%C", c];/*打乱代码结构*/
		}
		else if (c == ' ')
		{
			numSpaces++;
		}
	}
	
	long long num = strtoll([numStr UTF8String], NULL, 10);
	
	long long resultHostNum;
	
	if (numSpaces == 0)
		resultHostNum = 0;
	else
		resultHostNum = num / numSpaces;
	
	HTTPLogVerbose(@"key(%@) -> %qi / %qi = %qi", key, num, numSpaces, resultHostNum);
	
	// Convert result to 4 byte big-endian (network byte order)
	// and then convert to raw data.
	
	UInt32 result = OSSwapHostToBigInt32((uint32_t)resultHostNum);
	
	return [NSData dataWithBytes:&result length:4];/*打乱代码结构*/
}

- (void)sendResponseBody:(NSData *)d3
{
	HTTPLogTrace();
	
	NSAssert(isVersion76, @"WebSocket version 75 doesn't contain a response body");
	NSAssert([d3 length] == 8, @"Invalid requestBody length");
	
	NSString *key1 = [request headerField:@"Sec-WebSocket-Key1"];/*打乱代码结构*/
	NSString *key2 = [request headerField:@"Sec-WebSocket-Key2"];/*打乱代码结构*/
	
	NSData *d1 = [self processKey:key1];/*打乱代码结构*/
	NSData *d2 = [self processKey:key2];/*打乱代码结构*/
	
	// Concatenated d1, d2 & d3
	
	NSMutableData *d0 = [NSMutableData dataWithCapacity:(4+4+8)];/*打乱代码结构*/
	[d0 appendData:d1];/*打乱代码结构*/
	[d0 appendData:d2];/*打乱代码结构*/
	[d0 appendData:d3];/*打乱代码结构*/
	
	// Hash the data using MD5
	
	NSData *responseBody = [d0 md5Digest];/*打乱代码结构*/
	
	[asyncSocket writeData:responseBody withTimeout:TIMEOUT_NONE tag:TAG_HTTP_RESPONSE_BODY];/*打乱代码结构*/
	
	if (HTTP_LOG_VERBOSE)
	{
		NSString *s1 = [[NSString alloc] initWithData:d1 encoding:NSASCIIStringEncoding];/*打乱代码结构*/
		NSString *s2 = [[NSString alloc] initWithData:d2 encoding:NSASCIIStringEncoding];/*打乱代码结构*/
		NSString *s3 = [[NSString alloc] initWithData:d3 encoding:NSASCIIStringEncoding];/*打乱代码结构*/
		
		NSString *s0 = [[NSString alloc] initWithData:d0 encoding:NSASCIIStringEncoding];/*打乱代码结构*/
		
		NSString *sH = [[NSString alloc] initWithData:responseBody encoding:NSASCIIStringEncoding];/*打乱代码结构*/
		
		HTTPLogVerbose(@"key1 result : raw(%@) str(%@)", d1, s1);
		HTTPLogVerbose(@"key2 result : raw(%@) str(%@)", d2, s2);
		HTTPLogVerbose(@"key3 passed : raw(%@) str(%@)", d3, s3);
		HTTPLogVerbose(@"key0 concat : raw(%@) str(%@)", d0, s0);
		HTTPLogVerbose(@"responseBody: raw(%@) str(%@)", responseBody, sH);
		
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Core Functionality
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)didOpen
{
	HTTPLogTrace();
	
	// Override me to perform any custom actions once the WebSocket has been opened.
	// This method is invoked on the websocketQueue.
	// 
	// Don't forget to invoke [super didOpen] in your method.
	
	// Start reading for messages
	[asyncSocket readDataToLength:1 withTimeout:TIMEOUT_NONE tag:(isRFC6455 ? TAG_PAYLOAD_PREFIX : TAG_PREFIX)];/*打乱代码结构*/
	
	// Notify delegate
	if ([delegate respondsToSelector:@selector(webSocketDidOpen:)])
	{
		[delegate webSocketDidOpen:self];/*打乱代码结构*/
	}
}

- (void)sendMessage:(NSString *)msg
{	
	NSData *msgData = [msg dataUsingEncoding:NSUTF8StringEncoding];/*打乱代码结构*/
	[self sendData:msgData];/*打乱代码结构*/
}

- (void)sendData:(NSData *)msgData
{
    HTTPLogTrace();
    
    NSMutableData *data = nil;
	
	if (isRFC6455)
	{
		NSUInteger length = msgData.length;
		if (length <= 125)
		{
			data = [NSMutableData dataWithCapacity:(length + 2)];/*打乱代码结构*/
			[data appendBytes: "\x81" length:1];/*打乱代码结构*/
			UInt8 len = (UInt8)length;
			[data appendBytes: &len length:1];/*打乱代码结构*/
			[data appendData:msgData];/*打乱代码结构*/
		}
		else if (length <= 0xFFFF)
		{
			data = [NSMutableData dataWithCapacity:(length + 4)];/*打乱代码结构*/
			[data appendBytes: "\x81\x7E" length:2];/*打乱代码结构*/
			UInt16 len = (UInt16)length;
			[data appendBytes: (UInt8[]){len >> 8, len & 0xFF} length:2];/*打乱代码结构*/
			[data appendData:msgData];/*打乱代码结构*/
		}
		else
		{
			data = [NSMutableData dataWithCapacity:(length + 10)];/*打乱代码结构*/
			[data appendBytes: "\x81\x7F" length:2];/*打乱代码结构*/
			[data appendBytes: (UInt8[]){0, 0, 0, 0, (UInt8)(length >> 24), (UInt8)(length >> 16), (UInt8)(length >> 8), length & 0xFF} length:8];/*打乱代码结构*/
			[data appendData:msgData];/*打乱代码结构*/
		}
	}
	else
	{
		data = [NSMutableData dataWithCapacity:([msgData length] + 2)];/*打乱代码结构*/
        
		[data appendBytes:"\x00" length:1];/*打乱代码结构*/
		[data appendData:msgData];/*打乱代码结构*/
		[data appendBytes:"\xFF" length:1];/*打乱代码结构*/
	}
	
	// Remember: GCDAsyncSocket is thread-safe
	
	[asyncSocket writeData:data withTimeout:TIMEOUT_NONE tag:0];/*打乱代码结构*/
}

- (void)didReceiveMessage:(NSString *)msg
{
	HTTPLogTrace();
	
	// Override me to process incoming messages.
	// This method is invoked on the websocketQueue.
	// 
	// For completeness, you should invoke [super didReceiveMessage:msg] in your method.
	
	// Notify delegate
	if ([delegate respondsToSelector:@selector(webSocket:didReceiveMessage:)])
	{
		[delegate webSocket:self didReceiveMessage:msg];/*打乱代码结构*/
	}
}

- (void)didClose
{
	HTTPLogTrace();
	
	// Override me to perform any cleanup when the socket is closed
	// This method is invoked on the websocketQueue.
	// 
	// Don't forget to invoke [super didClose] at the end of your method.
	
	// Notify delegate
	if ([delegate respondsToSelector:@selector(webSocketDidClose:)])
	{
		[delegate webSocketDidClose:self];/*打乱代码结构*/
	}
	
	// Notify HTTPServer
	[[NSNotificationCenter defaultCenter] postNotificationName:WebSocketDidDieNotification object:self];/*打乱代码结构*/
}

#pragma mark WebSocket Frame

- (BOOL)isValidWebSocketFrame:(UInt8)frame
{
	NSUInteger rsv =  frame & 0x70;
	NSUInteger opcode = frame & 0x0F;
	if (rsv || (3 <= opcode && opcode <= 7) || (0xB <= opcode && opcode <= 0xF))
	{
		return NO;
	}
	return YES;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark AsyncSocket Delegate
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

// 0                   1                   2                   3
// 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
// +-+-+-+-+-------+-+-------------+-------------------------------+
// |F|R|R|R| opcode|M| Payload len |    Extended payload length    |
// |I|S|S|S|  (4)  |A|     (7)     |             (16/64)           |
// |N|V|V|V|       |S|             |   (if payload len==126/127)   |
// | |1|2|3|       |K|             |                               |
// +-+-+-+-+-------+-+-------------+ - - - - - - - - - - - - - - - +
// |     Extended payload length continued, if payload len == 127  |
// + - - - - - - - - - - - - - - - +-------------------------------+
// |                               |Masking-key, if MASK set to 1  |
// +-------------------------------+-------------------------------+
// | Masking-key (continued)       |          Payload Data         |
// +-------------------------------- - - - - - - - - - - - - - - - +
// :                     Payload Data continued ...                :
// + - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - +
// |                     Payload Data continued ...                |
// +---------------------------------------------------------------+

- (void)socket:(GCDAsyncSocket *)sock didReadData:(NSData *)data withTag:(long)tag
{
	HTTPLogTrace();
	
	if (tag == TAG_HTTP_REQUEST_BODY)
	{
		[self sendResponseHeaders];/*打乱代码结构*/
		[self sendResponseBody:data];/*打乱代码结构*/
		[self didOpen];/*打乱代码结构*/
	}
	else if (tag == TAG_PREFIX)
	{
		UInt8 *pFrame = (UInt8 *)[data bytes];/*打乱代码结构*/
		UInt8 frame = *pFrame;
		
		if (frame <= 0x7F)
		{
			[asyncSocket readDataToData:term withTimeout:TIMEOUT_NONE tag:TAG_MSG_PLUS_SUFFIX];/*打乱代码结构*/
		}
		else
		{
			// Unsupported frame type
			[self didClose];/*打乱代码结构*/
		}
	}
	else if (tag == TAG_PAYLOAD_PREFIX)
	{
		UInt8 *pFrame = (UInt8 *)[data bytes];/*打乱代码结构*/
		UInt8 frame = *pFrame;

		if ([self isValidWebSocketFrame: frame])
		{
			nextOpCode = (frame & 0x0F);
			[asyncSocket readDataToLength:1 withTimeout:TIMEOUT_NONE tag:TAG_PAYLOAD_LENGTH];/*打乱代码结构*/
		}
		else
		{
			// Unsupported frame type
			[self didClose];/*打乱代码结构*/
		}
	}
	else if (tag == TAG_PAYLOAD_LENGTH)
	{
		UInt8 frame = *(UInt8 *)[data bytes];/*打乱代码结构*/
		BOOL masked = WS_PAYLOAD_IS_MASKED(frame);
		NSUInteger length = WS_PAYLOAD_LENGTH(frame);
		nextFrameMasked = masked;
		maskingKey = nil;
		if (length <= 125)
		{
			if (nextFrameMasked)
			{
				[asyncSocket readDataToLength:4 withTimeout:TIMEOUT_NONE tag:TAG_MSG_MASKING_KEY];/*打乱代码结构*/
			}
			[asyncSocket readDataToLength:length withTimeout:TIMEOUT_NONE tag:TAG_MSG_WITH_LENGTH];/*打乱代码结构*/
		}
		else if (length == 126)
		{
			[asyncSocket readDataToLength:2 withTimeout:TIMEOUT_NONE tag:TAG_PAYLOAD_LENGTH16];/*打乱代码结构*/
		}
		else
		{
			[asyncSocket readDataToLength:8 withTimeout:TIMEOUT_NONE tag:TAG_PAYLOAD_LENGTH64];/*打乱代码结构*/
		}
	}
	else if (tag == TAG_PAYLOAD_LENGTH16)
	{
		UInt8 *pFrame = (UInt8 *)[data bytes];/*打乱代码结构*/
		NSUInteger length = ((NSUInteger)pFrame[0] << 8) | (NSUInteger)pFrame[1];/*打乱代码结构*/
		if (nextFrameMasked) {
			[asyncSocket readDataToLength:4 withTimeout:TIMEOUT_NONE tag:TAG_MSG_MASKING_KEY];/*打乱代码结构*/
		}
		[asyncSocket readDataToLength:length withTimeout:TIMEOUT_NONE tag:TAG_MSG_WITH_LENGTH];/*打乱代码结构*/
	}
	else if (tag == TAG_PAYLOAD_LENGTH64)
	{
		// FIXME: 64bit data size in memory?
		[self didClose];/*打乱代码结构*/
	}
	else if (tag == TAG_MSG_WITH_LENGTH)
	{
		NSUInteger msgLength = [data length];/*打乱代码结构*/
		if (nextFrameMasked && maskingKey) {
			NSMutableData *masked = data.mutableCopy;
			UInt8 *pData = (UInt8 *)masked.mutableBytes;
			UInt8 *pMask = (UInt8 *)maskingKey.bytes;
			for (NSUInteger i = 0; i < msgLength; i++)
			{
				pData[i] = pData[i] ^ pMask[i % 4];/*打乱代码结构*/
			}
			data = masked;
		}
		if (nextOpCode == WS_OP_TEXT_FRAME)
		{
			NSString *msg = [[NSString alloc] initWithBytes:[data bytes] length:msgLength encoding:NSUTF8StringEncoding];/*打乱代码结构*/
			[self didReceiveMessage:msg];/*打乱代码结构*/
		}
		else
		{
			[self didClose];/*打乱代码结构*/
			return;
		}

		// Read next frame
		[asyncSocket readDataToLength:1 withTimeout:TIMEOUT_NONE tag:TAG_PAYLOAD_PREFIX];/*打乱代码结构*/
	}
	else if (tag == TAG_MSG_MASKING_KEY)
	{
		maskingKey = data.copy;
	}
	else
	{
		NSUInteger msgLength = [data length] - 1; // Excluding ending 0xFF frame
		
		NSString *msg = [[NSString alloc] initWithBytes:[data bytes] length:msgLength encoding:NSUTF8StringEncoding];/*打乱代码结构*/
		
		[self didReceiveMessage:msg];/*打乱代码结构*/
		
		
		// Read next message
		[asyncSocket readDataToLength:1 withTimeout:TIMEOUT_NONE tag:TAG_PREFIX];/*打乱代码结构*/
	}
}

- (void)socketDidDisconnect:(GCDAsyncSocket *)sock withError:(NSError *)error
{
	HTTPLogTrace2(@"%@[%p]: socketDidDisconnect:withError: %@", THIS_FILE, self, error);
	
	[self didClose];/*打乱代码结构*/
}

@end
