/*
 * MacGDBp
 * Copyright (c) 2007 - 2011, Blue Static <http://www.bluestatic.org>
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

#import "DebuggerController.h"

#import "AppDelegate.h"
#import "BSSourceView.h"
#import "BreakpointController.h"
#import "BreakpointManager.h"
#import "DebuggerBackEnd.h"
#import "DebuggerModel.h"
#import "EvalController.h"
#import "PreferenceNames.h"
#import "NSXMLElementAdditions.h"
#import "StackFrame.h"

@interface DebuggerController (Private)
- (void)updateSourceViewer;
- (void)expandVariables;
@end

@implementation DebuggerController {
  BreakpointController* _breakpointsController;
  EvalController* _evalController;
}

@synthesize connection, sourceViewer, inspector;

/**
 * Initializes the window controller and sets the connection using preference
 * values
 */
- (id)init
{
  if (self = [super initWithWindowNibName:@"Debugger"])
  {
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];

    _model = [[DebuggerModel alloc] init];
    [_model addObserver:self
             forKeyPath:@"connected"
                options:NSKeyValueObservingOptionNew
                context:nil];

    connection = [[DebuggerBackEnd alloc] initWithPort:[defaults integerForKey:kPrefPort]
                                            autoAttach:[defaults boolForKey:kPrefDebuggerAttached]];
    connection.model = _model;
    _model.breakpointManager.connection = connection;

    [_model addObserver:self
             forKeyPath:@"status"
                options:NSKeyValueObservingOptionNew
                context:nil];

    expandedVariables = [[NSMutableSet alloc] init];
    [[self window] makeKeyAndOrderFront:nil];
    [[self window] setDelegate:self];
    
    if ([defaults boolForKey:kPrefInspectorWindowVisible])
      [inspector orderFront:self];
  }
  return self;
}

/**
 * Dealloc
 */
- (void)dealloc
{
  [connection release];
  [_model release];
  [_breakpointsController release];
  [_evalController release];
  [expandedVariables release];
  [super dealloc];
}

/**
 * Before the display get's comfortable, set up the NSTextView to scroll horizontally
 */
- (void)awakeFromNib
{
  [[self window] setExcludedFromWindowsMenu:YES];
  [[self window] setTitle:[NSString stringWithFormat:@"MacGDBp @ %d", [connection port]]];
  [sourceViewer setDelegate:self];
  [stackArrayController setSortDescriptors:@[ [[[NSSortDescriptor alloc] initWithKey:@"index" ascending:YES] autorelease] ]];
  [stackArrayController addObserver:self
                         forKeyPath:@"selectedObjects"
                            options:NSKeyValueObservingOptionNew
                            context:nil];
  [stackArrayController addObserver:self
                         forKeyPath:@"selection.source"
                            options:NSKeyValueObservingOptionNew
                            context:nil];
  self.connection.autoAttach = [attachedCheckbox_ state] == NSOnState;

  // Load view controllers into the tab views.
  _breakpointsController = [[BreakpointController alloc] initWithBreakpointManager:_model.breakpointManager
                                                                        sourceView:sourceViewer];
  [[self.tabView tabViewItemAtIndex:1] setView:_breakpointsController.view];

  _evalController = [[EvalController alloc] initWithBackEnd:connection];
  [[self.tabView tabViewItemAtIndex:2] setView:_evalController.view];

  // When the segment control's selection changes, update the tab view.
  [[_segmentControl cell] addObserver:self
                           forKeyPath:@"selectedSegment"
                              options:0
                              context:nil];
  // When the segment control's superview changes, recalculate the spacer
  // segment widths.
  [[_segmentControl superview] addObserver:self
                                forKeyPath:@"frame"
                                   options:0
                                   context:nil];

  NSUInteger selectedSegment =
      [[[NSUserDefaults standardUserDefaults] valueForKey:kPrefSelectedDebuggerSegment] intValue];
  [[_segmentControl cell] setSelectedSegment:selectedSegment];
  [self updateSegmentControl];
}

/**
 * Key-value observation routine.
 */
- (void)observeValueForKeyPath:(NSString*)keyPath
                      ofObject:(id)object
                        change:(NSDictionary<NSString*,id>*)change
                       context:(void*)context {
  if (object == stackArrayController && [keyPath isEqualToString:@"selectedObjects"]) {
    for (StackFrame* frame in stackArrayController.selectedObjects)
      [connection loadStackFrame:frame];
  } else if (object == stackArrayController && [keyPath isEqualToString:@"selection.source"]) {
    [self updateSourceViewer];
  } else if (object == _model) {
    if ([keyPath isEqualToString:@"connected"]) {
      if ([change[NSKeyValueChangeNewKey] boolValue]) {
        [self debuggerConnected];
      } else {
        [self debuggerDisconnected];
      }
    } else if ([keyPath isEqualToString:@"status"]) {
      self.statusField.textColor = self.model.lastError ? [NSColor redColor] : [NSColor textColor];
    }
  } else if (object == _segmentControl.cell) {
    [[NSUserDefaults standardUserDefaults] setValue:@(_segmentControl.selectedSegment)
                                             forKey:kPrefSelectedDebuggerSegment];
    [_tabView selectTabViewItemAtIndex:_segmentControl.selectedSegment - 1];
  } else if (object == _segmentControl.superview) {
    [self updateSegmentControl];
  } else {
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
  }
}

/**
 * Validates the menu items for the "Debugger" menu
 */
- (BOOL)validateUserInterfaceItem:(id <NSValidatedUserInterfaceItem>)anItem
{
  SEL action = [anItem action];
  
  if (action == @selector(stepOut:)) {
    return _model.connected && _model.stackDepth > 1;
  } else if (action == @selector(stepIn:) ||
             action == @selector(stepOver:) ||
             action == @selector(run:) ||
             action == @selector(stop:)) {
    return _model.connected;
  }
  return [[self window] validateUserInterfaceItem:anItem];
}

/**
 * Shows the inspector window
 */
- (IBAction)showInspectorWindow:(id)sender
{
  if (![inspector isVisible])
    [inspector makeKeyAndOrderFront:sender];
  else
    [inspector orderOut:sender];
}

/**
 * Runs the eval window sheet.
 */
- (IBAction)showEvalWindow:(id)sender
{
  [self.segmentControl setSelectedSegment:3];
}

/**
 * Resets all the displays to be empty
 */
- (void)resetDisplays
{
  [variablesTreeController setContent:nil];
  [stackArrayController rearrangeObjects];
  [[sourceViewer textView] setString:@""];
  sourceViewer.file = nil;
}


/**
 * Delegate function for GDBpConnection for when the debugger connects.
 */
- (void)debuggerConnected
{
  if (!self.connection.autoAttach)
    return;
  if ([[NSUserDefaults standardUserDefaults] boolForKey:kPrefBreakOnFirstLine])
    [self stepIn:self];
  // Do not cache the file between debugger executions.
  sourceViewer.file = nil;
}

/**
 * Called once the debugger disconnects.
 */
- (void)debuggerDisconnected
{
  // Invalidate the marked line so we don't look like we're still running.
  sourceViewer.markedLine = -1;
  [sourceViewer setNeedsDisplay:YES];
}

/**
 * Forwards the message to run script execution to the connection
 */
- (IBAction)run:(id)sender
{
  [connection run];
}

- (IBAction)attachedToggled:(id)sender
{
  connection.autoAttach = [sender state] == NSOnState;
}

/**
 * Forwards the message to "step in" to the connection
 */
- (IBAction)stepIn:(id)sender
{
  if ([[variablesTreeController selectedObjects] count] > 0)
    selectedVariable = [[variablesTreeController selectedObjects] objectAtIndex:0];
  
  [connection stepIn];
}

/**
 * Forwards the message to "step out" to the connection
 */
- (IBAction)stepOut:(id)sender
{
  if ([[variablesTreeController selectedObjects] count] > 0)
    selectedVariable = [[variablesTreeController selectedObjects] objectAtIndex:0];
  
  [connection stepOut];
}

/**
 * Forwards the message to "step over" to the connection
 */
- (IBAction)stepOver:(id)sender
{
  if ([[variablesTreeController selectedObjects] count] > 0)
    selectedVariable = [[variablesTreeController selectedObjects] objectAtIndex:0];
  
  [connection stepOver];
}

/**
 * Forwards the detach/"stop" message to the back end.
 */
- (IBAction)stop:(id)sender
{
  [connection stop];
}

/**
 * NSTableView delegate method that informs the controller that the stack selection did change and that
 * we should update the source viewer
 */
- (void)tableViewSelectionDidChange:(NSNotification*)notif
{
  // TODO: This is very, very hacky because it's nondeterministic. The issue
  // is that calling |-[NSOutlineView expandItem:]| while the table is still
  // doing its redraw will translate to a no-op. Instead, we need to restructure
  // this controller so that when everything has been laid out we call
  // |-expandVariables|; but NSOutlineView doesn't have a |-didFinishDoingCrap:|
  // method. The other issue is that we need to call this method from
  // selectionDidChange but ONLY when it was the result of a user-initiated
  // action and not the stack viewer updating causing a selection change.
  // If it happens in the latter, then we run into the same issue that causes
  // this to no-op.
  [self performSelector:@selector(expandVariables) withObject:nil afterDelay:0.05];
}

/**
 * Called whenver an item is expanded. This allows us to determine if we need to fetch deeper
 */
- (void)outlineViewItemDidExpand:(NSNotification*)notif
{
  NSTreeNode* node = [[notif userInfo] objectForKey:@"NSObject"];
  [expandedVariables addObject:[[node representedObject] fullName]];

  [connection loadVariableNode:[node representedObject]
                 forStackFrame:[[stackArrayController selectedObjects] lastObject]];
}

/**
 * Called when an item was collapsed. This allows us to remove it from the list of expanded items
 */
- (void)outlineViewItemDidCollapse:(NSNotification*)notif
{
  [expandedVariables removeObject:[[[[notif userInfo] objectForKey:@"NSObject"] representedObject] fullName]];
}

#pragma mark Private

/**
 * Does the actual updating of the source viewer by reading in the file
 */
- (void)updateSourceViewer
{
  NSArray* selection = [stackArrayController selectedObjects];
  if (!selection || [selection count] < 1)
    return;
  if ([selection count] > 1)
    NSLog(@"INVALID SELECTION");
  StackFrame* frame = [selection objectAtIndex:0];

  if (!frame.loaded) {
    [connection loadStackFrame:frame];
    return;
  }

  // Get the filename.
  NSString* filename = [[NSURL URLWithString:frame.filename] path];
  if ([filename isEqualToString:@""])
    return;
  
  // Replace the source if necessary.
  if (frame.source && ![sourceViewer.file isEqualToString:filename])
  {
    [sourceViewer setString:frame.source asFile:filename];
    
    NSSet<NSNumber*>* breakpoints = [_model.breakpointManager breakpointsForFile:filename];
    [sourceViewer setMarkers:breakpoints];
  }
  
  [sourceViewer setMarkedLine:frame.lineNumber];
  [sourceViewer scrollToLine:frame.lineNumber];
  
  [[sourceViewer textView] setNeedsDisplay:YES];
}

/**
 * Expands the variables based on the stored set
 */
- (void)expandVariables
{
  NSString* selection = [selectedVariable fullName];

  for (NSInteger i = 0; i < [variablesOutlineView numberOfRows]; i++) {
    NSTreeNode* node = [variablesOutlineView itemAtRow:i];
    NSString* fullName = [[node representedObject] fullName];
    
    // see if it needs expanding
    if ([expandedVariables containsObject:fullName])
      [variablesOutlineView expandItem:node];
    
    // select it if we had it selected before
    if ([fullName isEqualToString:selection])
      [variablesTreeController setSelectionIndexPath:[node indexPath]];
  }
}

/**
 * Sets the widths of the segmented control.
 */
- (void)updateSegmentControl {
  NSRect containerFrame = [[_segmentControl superview] frame];
  CGFloat containerWidth = NSWidth(containerFrame);
  CGFloat segmentSizes = 0;
  for (NSInteger i = 1; i < [_segmentControl segmentCount] - 1; ++i) {
    segmentSizes += [_segmentControl widthForSegment:i];
  }
  CGFloat spacerWidth = (containerWidth - segmentSizes) / 2;
  [_segmentControl setWidth:spacerWidth forSegment:0];
  [_segmentControl setWidth:spacerWidth forSegment:[_segmentControl segmentCount] - 1];

  [_segmentControl setFrame:NSMakeRect(-1, NSHeight(containerFrame) - 27, containerWidth + 2, 30)];
}

#pragma mark BSSourceView Delegate

/**
 * The gutter was clicked, which indicates that a breakpoint needs to be changed
 */
- (void)gutterClickedAtLine:(int)line forFile:(NSString*)file
{
  BreakpointManager* manager = _model.breakpointManager;
  Breakpoint* breakpoint = [Breakpoint breakpointAtLine:line inFile:file];
  
  if ([manager hasBreakpoint:breakpoint]) {
    [manager removeBreakpoint:breakpoint];
  } else {
    [manager addBreakpoint:breakpoint];
  }
  
  [sourceViewer setMarkers:[manager breakpointsForFile:file]];
}

@end
