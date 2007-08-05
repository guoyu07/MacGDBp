/*
 * MacGDBp
 * Copyright (c) 2002 - 2007, Blue Static <http://www.bluestatic.org>
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

#import "DebuggerWindowController.h"
#import "DebuggerConnection.h"

@interface DebuggerWindowController (Private)

- (void)updateSourceViewer;

@end

@implementation DebuggerWindowController

/**
 * Initializes the window controller and sets the connection
 */
- (id)initWithConnection: (DebuggerConnection *)cnx
{
	if (self = [super initWithWindowNibName: @"Debugger"])
	{
		_connection = [cnx retain];
	}
	return self;
}

/**
 * Before the display get's comfortable, set up the NSTextView to scroll horizontally
 */
- (void)awakeFromNib
{
	// set up the scroller for the source viewer
	[_sourceViewer setMaxSize: NSMakeSize(FLT_MAX, FLT_MAX)];
	[[_sourceViewer textContainer] setContainerSize: NSMakeSize(FLT_MAX, FLT_MAX)];
	[[_sourceViewer textContainer] setWidthTracksTextView: NO];
	[_sourceViewer setHorizontallyResizable: YES];
	[_sourceViewerScroller setHasHorizontalScroller: YES];
	[_sourceViewerScroller display];
}

/**
 * Release object members
 */
- (void)dealloc
{
	[_connection release];
	
	[super dealloc];
}

/**
 * Sets the status and clears any error message
 */
- (void)setStatus: (NSString *)status
{
	[_error setHidden: YES];
	[_status setStringValue: status];
	[[self window] setTitle: [NSString stringWithFormat: @"GDBp @ %@:%d/%@", [_connection remoteHost], [_connection port], [_connection session]]];
}

/**
 * Sets the status to be "Error" and then displays the error message
 */
- (void)setError: (NSString *)error
{
	[_error setStringValue: error];
	[self setStatus: @"Error"];
	[_error setHidden: NO];
}

/**
 * Sets the root node element of the stacktrace
 */
- (void)setStack: (NSArray *)stack
{
	if (_stack != nil)
	{
		[_stack release];
	}
	
	_stack = stack;
	[_stack retain];
	[self updateSourceViewer];
}

/**
 * Sets the stack root element so that the NSOutlineView can display it
 */
- (void)setRegister: (NSXMLElement *)elm
{
	if (_register != nil)
	{
		[_register release];
	}
	
	_register = elm;
	[_register retain];
}

/**
 * Forwards the message to run script execution to the connection
 */
- (IBAction)run: (id)sender
{
	[_connection run];
}

/**
 * Forwards the message to "step in" to the connection
 */
- (IBAction)stepIn: (id)sender
{
	[_connection stepIn];
}

/**
* Forwards the message to "step out" to the connection
 */
- (IBAction)stepOut: (id)sender
{
	[_connection stepOut];
}

/**
* Forwards the message to "step over" to the connection
 */
- (IBAction)stepOver: (id)sender
{
	[_connection stepOver];
}

/**
 * NSTableView delegate method that informs the controller that the stack selection did change and that
 * we should update the source viewer
 */
- (void)tableViewSelectionDidChange: (NSNotification *)notif
{
	[self updateSourceViewer];
}
/**
 * Does the actual updating of the source viewer by reading in the file
 */
- (void)updateSourceViewer
{
	int selection = [_stackController selectionIndex];
	if (selection == NSNotFound)
	{
		[_sourceViewer setString: @""];
		return;
	}
	
	// get the filename and then set the text
	NSString *filename = [[_stack objectAtIndex: selection] valueForKey: @"filename"];
	filename = [[NSURL URLWithString: filename] path];
	NSString *text = [NSString stringWithContentsOfFile: filename];
	[_sourceViewer setString: text];
	
	// go through the document until we find the NSRange for the line we want
	int destination = [[[_stack objectAtIndex: selection] valueForKey: @"lineno"] intValue];
	int rangeIndex = 0;
	for (int line = 0; line < destination; line++)
	{
		rangeIndex = NSMaxRange([text lineRangeForRange: NSMakeRange(rangeIndex, 0)]);
	}
	
	// now get the true start/end markers for it
	unsigned lineStart, lineEnd;
	[text getLineStart: &lineStart end: NULL contentsEnd: &lineEnd forRange: NSMakeRange(rangeIndex - 1, 0)];
	NSRange lineRange = NSMakeRange(lineStart, lineEnd - lineStart);
	
	// colorize it so the user knows which line we're on in the stack
	[[_sourceViewer textStorage] setAttributes: [NSDictionary dictionaryWithObjects: [NSArray arrayWithObjects: [NSColor redColor], [NSColor yellowColor], nil]
																			 forKeys: [NSArray arrayWithObjects: NSForegroundColorAttributeName, NSBackgroundColorAttributeName, nil]]
										 range: lineRange];
	[_sourceViewer scrollRangeToVisible: [text lineRangeForRange: NSMakeRange(lineStart, lineEnd - lineStart)]];
	
	// make sure the font stays Monaco
	[_sourceViewer setFont: [NSFont fontWithName: @"Monaco" size: 10.0]];
}

@end
