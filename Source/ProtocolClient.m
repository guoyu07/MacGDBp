/*
 * MacGDBp
 * Copyright (c) 2013, Blue Static <http://www.bluestatic.org>
 *
 * This program is free software; you can redistribute it and/or modify it under the terms of the GNU
 * General Public License as published by the Free Software Foundation; either version 2 of the
 * License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without
 * even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along with this program; if not,
 * write to the Free Software Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA
 */

#import "ProtocolClient.h"

@interface ProtocolClient (Private)
- (void)postReceivedMessage:(NSXMLDocument*)message;
@end

@implementation ProtocolClient

- (id)initWithDelegate:(NSObject<ProtocolClientDelegate>*)delegate {
  if ((self = [super init])) {
    _delegate = delegate;
    _delegateThread = [NSThread currentThread];
    _lock = [[NSRecursiveLock alloc] init];
  }
  return self;
}

- (void)dealloc {
  [_lock release];
  [super dealloc];
}

- (BOOL)isConnected {
  return [_messageQueue isConnected];
}

- (void)connectOnPort:(NSUInteger)port {
  assert(!_messageQueue);
  _messageQueue = [[MessageQueue alloc] initWithPort:port delegate:self];
  [_messageQueue connect];
}

- (void)disconnect {
  [_messageQueue disconnect];
}

- (NSNumber*)sendCommandWithFormat:(NSString*)format, ... {
  // Collect varargs and format command.
  va_list args;
  va_start(args, format);
  NSString* command = [[NSString alloc] initWithFormat:format arguments:args];
  va_end(args);

  NSNumber* callbackKey = [NSNumber numberWithInt:_nextID++];
  NSString* taggedCommand = [NSString stringWithFormat:@"%@ -i %@", [command autorelease], callbackKey];

  assert(_messageQueue);
  [_messageQueue sendMessage:taggedCommand];
  return callbackKey;
}

- (NSNumber*)sendCustomCommandWithFormat:(NSString*)format, ... {
  // Collect varargs and format command.
  va_list args;
  va_start(args, format);
  NSString* command = [[[NSString alloc] initWithFormat:format arguments:args] autorelease];
  va_end(args);

  NSNumber* callbackKey = [NSNumber numberWithInt:_nextID++];
  NSString* taggedCommand = [command stringByReplacingOccurrencesOfString:@"{txn}"
                                                               withString:[callbackKey stringValue]];

  [_messageQueue sendMessage:taggedCommand];
  return callbackKey;
}

- (NSInteger)transactionIDFromResponse:(NSXMLDocument*)response {
  return [[[[response rootElement] attributeForName:@"transaction_id"] stringValue] intValue];
}

- (NSInteger)transactionIDFromCommand:(NSString*)command {
  NSRange occurrence = [command rangeOfString:@"-i "];
  if (occurrence.location == NSNotFound)
    return NSNotFound;
  NSString* transaction = [command substringFromIndex:occurrence.location + occurrence.length];
  return [transaction intValue];
}

// MessageQueueDelegate ////////////////////////////////////////////////////////

- (void)messageQueueError:(NSError*)error {
  NSLog(@"error = %@", error);
}

- (void)clientDidConnect:(MessageQueue*)queue {
  [_lock lock];
  _nextID = 0;
  _lastReadID = 0;
  _lastWrittenID = 0;
  [_lock unlock];

  [_delegate performSelector:@selector(debuggerEngineConnected:)
                    onThread:_delegateThread
                  withObject:self
               waitUntilDone:NO];
}

- (void)clientDidDisconnect:(MessageQueue*)queue {
  [_delegate performSelector:@selector(debuggerEngineDisconnected:)
                    onThread:_delegateThread
                  withObject:self
               waitUntilDone:NO];
}

// If the write stream is ready, the delegate controls whether or not the next
// pending message should be sent via the result of this method.
- (BOOL)shouldSendMessage {
  [_lock lock];
  BOOL r = _lastReadID >= _lastWrittenID;
  [_lock unlock];
  return r;
}

// Callback for when a message has been sent.
- (void)didSendMessage:(NSString*)message {
  NSInteger tag = [self transactionIDFromCommand:message];
  [_lock lock];
  _lastWrittenID = tag;
  [_lock unlock];
}

// Callback with the message content when one has been receieved.
- (void)didReceiveMessage:(NSString*)message {
  // Test if we can convert it into an NSXMLDocument.
  NSError* error = nil;
  NSXMLDocument* xml = [[NSXMLDocument alloc] initWithXMLString:message
                                                        options:NSXMLDocumentTidyXML
                                                          error:&error];
  if (error) {
    [self messageQueueError:error];
    return;
  }

  // Validate the transaction.
  NSInteger transaction = [self transactionIDFromResponse:xml];
  if (transaction < _lastReadID) {
    NSLog(@"Transaction #%d is out of date (lastRead = %d). Dropping packet: %@",
          transaction, _lastReadID, message);
    return;
  }
  if (transaction != _lastWrittenID) {
    NSLog(@"Transaction #%d received out of order. lastRead = %d, lastWritten = %d. Continuing.",
          transaction, _lastReadID, _lastWrittenID);
  }

  _lastReadID = transaction;

  [self performSelector:@selector(postReceivedMessage:)
               onThread:_delegateThread
             withObject:xml
          waitUntilDone:NO
                  modes:@[ NSDefaultRunLoopMode ]];
}

// Private /////////////////////////////////////////////////////////////////////

- (void)postReceivedMessage:(NSXMLDocument*)message {
  [_delegate debuggerEngine:self receivedMessage:message];
}

@end
