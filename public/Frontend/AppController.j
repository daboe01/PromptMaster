/*
 * AppController.j
 * PromptMaster - Drag & Drop fähiger Prompt-Baum via Binder- & OutlineView-Category
 * Mit TabView im Ergebnis-Popover (Rich-Text & Markdown)
 */

@import <Foundation/Foundation.j>
@import <AppKit/AppKit.j>
@import <Renaissance/Renaissance.j>

var PromptDragType = @"PromptTreeNodeDragType";

// --------------------------------------------------------------------------------
// 1. Category auf _CPOutlineViewContentBinder
// Schaltet die internen Cappuccino-Bitmasken für Drag & Drop bei TreeController-Bindings frei
// und leitet die DataSource-Aufrufe an den OutlineView-Delegate weiter.
// --------------------------------------------------------------------------------

@implementation _CPOutlineViewContentBinder (PromptMasterDragAndDrop)

- (void)outlineView:(CPOutlineView)anOutlineView setObjectValue:(id)value forTableColumn:(CPTableColumn)tableColumn byItem:(id)item
{
    var node = item;
    if ([item respondsToSelector:@selector(representedObject)])
        node = [item representedObject];

    if (node && [tableColumn identifier] && [tableColumn identifier] !== @"")
    {
        // Setzt den neuen Titel auf dem Datenmodell
        [node setValue:value forKey:[tableColumn identifier]];

        // Informiert den AppController zur Synchronisation & AutoSave
        var app = [CPApp delegate];
        if (app && [app respondsToSelector:@selector(nodeDidInlineEdit:)])
            [app nodeDidInlineEdit:node];
    }
}

- (BOOL)outlineView:(CPOutlineView)anOutlineView writeItems:(CPArray)items toPasteboard:(CPPasteboard)pboard
{
    var del = [anOutlineView delegate];
    console.log("[D&D BINDER] writeItems aufgerufen. Items:", items, "Delegate:", del);
    if ([del respondsToSelector:@selector(outlineView:writeItems:toPasteboard:)])
    {
        var result = [del outlineView:anOutlineView writeItems:items toPasteboard:pboard];
        console.log("[D&D BINDER] Delegate writeItems Rückgabe:", result);
        return result;
    }
    console.warn("[D&D BINDER] Delegate reagiert NICHT auf outlineView:writeItems:toPasteboard:");
    return NO;
}

- (CPDragOperation)outlineView:(CPOutlineView)anOutlineView validateDrop:(id)info proposedItem:(id)anItem proposedChildIndex:(CPInteger)anIndex
{
    var del = [anOutlineView delegate];
    if ([del respondsToSelector:@selector(outlineView:validateDrop:proposedItem:proposedChildIndex:)])
        return [del outlineView:anOutlineView validateDrop:info proposedItem:anItem proposedChildIndex:anIndex];
    return CPDragOperationNone;
}

- (BOOL)outlineView:(CPOutlineView)anOutlineView acceptDrop:(id)info item:(id)anItem childIndex:(CPInteger)anIndex
{
    console.log("[D&D BINDER] acceptDrop aufgerufen.");
    var del = [anOutlineView delegate];
    if ([del respondsToSelector:@selector(outlineView:acceptDrop:item:childIndex:)])
        return [del outlineView:anOutlineView acceptDrop:info item:anItem childIndex:anIndex];
    return NO;
}

@end

// --------------------------------------------------------------------------------
// 2. Renaissance Custom Tag & OutlineView Subclass
// --------------------------------------------------------------------------------

@implementation GSMarkupTagPromptOutlineView : GSMarkupTagControl
+ (CPString)tagName { return @"PromptOutlineView"; }
+ (Class)platformObjectClass { return [PromptOutlineView class]; }
- (id)initPlatformObject:(id)platformObject
{
    platformObject = [super initPlatformObject:platformObject];
    var column = [[CPTableColumn alloc] initWithIdentifier:@"name"];
    [[column headerView] setStringValue:@"Prompts"];
    [column setResizingMask:CPTableColumnAutoresizingMask];
    
    // Spalte für Inline-Editing freischalten
    [column setEditable:YES];

    // DataView darf Mouse-Events im Ruhemodus nicht abfangen (wichtig für D&D)
    var dv = [column dataView];
    if (dv) {
        if ([dv respondsToSelector:@selector(setEditable:)]) [dv setEditable:NO];
        if ([dv respondsToSelector:@selector(setSelectable:)]) [dv setSelectable:NO];
        if ([dv respondsToSelector:@selector(setHitTests:)]) [dv setHitTests:NO];
    }

    [platformObject setColumnAutoresizingStyle:CPTableViewLastColumnOnlyAutoresizingStyle];
    [platformObject addTableColumn:column];
    [platformObject setOutlineTableColumn:column];
    [platformObject setAllowsMultipleSelection:NO];
    [platformObject setVerticalMotionCanBeginDrag:YES];
    [platformObject registerForDraggedTypes:[CPArray arrayWithObject:PromptDragType]];

    return platformObject;
}
@end

@implementation PromptOutlineView : CPOutlineView
- (GSAutoLayoutAlignment)autolayoutDefaultVerticalAlignment
{
    return GSAutoLayoutExpand;
}
- (GSAutoLayoutAlignment)autolayoutDefaultHorizontalAlignment
{
    return GSAutoLayoutExpand;
}
@end

// --------------------------------------------------------------------------------
// PromptNode Datenmodell
// --------------------------------------------------------------------------------

@implementation PromptNode : CPObject
{
    CPNumber _id            @accessors(property=id);
    CPNumber _parent_id     @accessors(property=parent_id);
    CPString _title         @accessors(property=title);
    CPString _prompt_text   @accessors(property=prompt_text);
    CPString _output_format @accessors(property=output_format);
    CPString _template_name @accessors(property=template_name);
    BOOL     _has_template  @accessors(property=has_template);
    int      _sort_order    @accessors(property=sort_order);
    CPArray  _children      @accessors(property=children);
}

- (id)initWithDict:(JSObject)dict
{
    self = [super init];
    if (self)
    {
        _id            = dict.id;
        _parent_id     = dict.parent_id;
        _title         = dict.title || @"Neuer Prompt";
        _prompt_text   = dict.prompt_text || @"";
        _output_format = dict.output_format || @"markdown";
        _template_name = dict.template_name || @"";
        _has_template  = (dict.has_template == 1 || dict.has_template === true) ? YES : NO;
        _sort_order    = dict.sort_order || 0;
        _children      = [CPMutableArray array];

        if (dict.children && dict.children.length)
        {
            for (var i = 0; i < dict.children.length; i++)
            {
                var child = [[PromptNode alloc] initWithDict:dict.children[i]];
                [_children addObject:child];
            }
        }
    }
    return self;
}

- (CPString)name
{
    return _title;
}

- (void)setName:(CPString)aName
{
    _title = aName;
}

- (BOOL)isLeaf
{
    return [_children count] === 0;
}

- (void)setChildren:(CPArray)newChildren
{
    _children = newChildren;
}

- (BOOL)hasDescendantWithId:(id)targetId
{
    for (var i = 0; i < [_children count]; i++)
    {
        var child = [_children objectAtIndex:i];
        if ([child id] == targetId)
            return YES;
        if ([child hasDescendantWithId:targetId])
            return YES;
    }
    return NO;
}

@end

// --------------------------------------------------------------------------------
// AppController
// --------------------------------------------------------------------------------

@implementation AppController : CPObject
{
    CPWindow          mainWindow;
    CPTreeController  treeController;

    // Outlets
    CPOutlineView     _outlineView;
    CPTabView         _mainTabView;

    // Tab 1: Konfigurieren
    CPTextField       _titleField;
    CPPopUpButton     _formatPopUp;
    CPTextView        _promptTextView;
    CPTextField       _templateIconLabel;
    CPTextField       _templateNameLabel;
    CPButton          _uploadTemplateBtn;
    CPButton          _downloadTemplateBtn;
    CPButton          _deleteTemplateBtn;
    CPButton          _saveBtn;

    // Tab 2: Anwenden
    CPTextView        _applyInputTextView;
    CPButton          _runButton;

    // Popover für Ausgabe mit Tabs (Rich-Text & Markdown)
    CPPopover         _markdownPopover;
    CPTabView         _popoverTabView;
    CPTextView        _popoverRichTextView;
    CPTextView        _popoverMarkdownTextView;
    CPString          _currentOutputMarkdown;

    // State
    CPString          selectedModel @accessors;
    CPMutableArray    _rootNodes;
    PromptNode        _activeSelectedNode;
    BOOL              _isProgrammaticUpdate;
    id                _autoSaveTimer;
}

- (void)applicationDidFinishLaunching:(CPNotification)aNotification
{
    _rootNodes = [CPMutableArray array];
    _isProgrammaticUpdate = NO;
    _autoSaveTimer = nil;
    _currentOutputMarkdown = @"";
    [self setSelectedModel:@"gemma4:26b-mlx"];

    // 1. CPTreeController initialisieren
    treeController = [[CPTreeController alloc] init];
    [treeController setChildrenKeyPath:@"children"];
    [treeController setLeafKeyPath:@"isLeaf"];

    [CPBundle loadRessourceNamed:@"model.gsmarkup" owner:self];
    [CPBundle loadRessourceNamed:@"gui.gsmarkup" owner:self];

    // 2. OutlineView & Spalten für D&D absichern
    if ([[_outlineView tableColumns] count] === 0)
    {
        var column = [[CPTableColumn alloc] initWithIdentifier:@"name"];
        [[column headerView] setStringValue:@"Prompts"];
        [column setResizingMask:CPTableColumnAutoresizingMask];
        [_outlineView setColumnAutoresizingStyle:CPTableViewLastColumnOnlyAutoresizingStyle];
        [_outlineView addTableColumn:column];
        [_outlineView setOutlineTableColumn:column];
    }

    var cols = [_outlineView tableColumns];
    for (var i = 0; i < [cols count]; i++)
    {
        var col = [cols objectAtIndex:i];
        var dv = [col dataView];
        if (dv) {
            if ([dv respondsToSelector:@selector(setEditable:)]) [dv setEditable:NO];
            if ([dv respondsToSelector:@selector(setSelectable:)]) [dv setSelectable:NO];
            if ([dv respondsToSelector:@selector(setHitTests:)]) [dv setHitTests:NO];
        }
    }

    [_outlineView setDelegate:self];
    [_outlineView setAllowsMultipleSelection:NO];
    [_outlineView setVerticalMotionCanBeginDrag:YES];
    [_outlineView setDraggingDestinationFeedbackStyle:CPTableViewDraggingDestinationFeedbackStyleSourceList];
    [_outlineView registerForDraggedTypes:[CPArray arrayWithObject:PromptDragType]];

    // 3. TreeController Binden
    [_outlineView bind:@"content" toObject:treeController withKeyPath:@"arrangedObjects" options:nil];
    [_outlineView bind:@"selectionIndexPaths" toObject:treeController withKeyPath:@"selectionIndexPaths" options:nil];

    // 4. Delegate & Notifications für Live-Editing
    [_titleField setDelegate:self];
    [_promptTextView setDelegate:self];

    [[CPNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(controlTextDidChange:)
                                                 name:CPControlTextDidChangeNotification
                                               object:_titleField];

    [[CPNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(textDidChange:)
                                                 name:CPTextDidChangeNotification
                                               object:_promptTextView];

    // 5. Drag & Drop Listener auf dem Upload-Button einrichten
    [self setupUploadButtonDragAndDrop];

    // 6. Run-Button Styling
    if (_runButton)
    {
        [_runButton setFont:[CPFont boldSystemFontOfSize:13.0]];
        _runButton._DOMElement.style.backgroundColor = "#007AFF";
        _runButton._DOMElement.style.color = "white";
        _runButton._DOMElement.style.borderRadius = "6px";
        _runButton._DOMElement.style.cursor = "pointer";
    }

    [self updateDetailFormWithNode:nil];

    [mainWindow makeKeyAndOrderFront:self];
    [self loadPromptTree];
}

// --------------------------------------------------------------------------------
// Drag & Drop Delegate-Methoden für den OutlineView
// --------------------------------------------------------------------------------

- (BOOL)outlineView:(CPOutlineView)ov writeItems:(CPArray)items toPasteboard:(CPPasteboard)pboard
{
    if (!items || [items count] === 0) return NO;

    var item = [items objectAtIndex:0];
    var node = item;
    if ([item respondsToSelector:@selector(representedObject)]) {
        node = [item representedObject];
    }

    if (!node || [node id] === nil || [node id] === undefined) return NO;

    [pboard declareTypes:[CPArray arrayWithObject:PromptDragType] owner:self];
    [pboard setString:String([node id]) forType:PromptDragType];

    return YES;
}

- (CPDragOperation)outlineView:(CPOutlineView)ov validateDrop:(id)info proposedItem:(id)item proposedChildIndex:(CPInteger)childIndex
{
    var pboard = [info draggingPasteboard];
    if (![pboard availableTypeFromArray:[CPArray arrayWithObject:PromptDragType]]) {
        return CPDragOperationNone;
    }

    var draggedIdStr = [pboard stringForType:PromptDragType];
    if (!draggedIdStr) return CPDragOperationNone;

    var draggedId = parseInt(draggedIdStr, 10);
    var targetNode = item;
    if (item && [item respondsToSelector:@selector(representedObject)]) {
        targetNode = [item representedObject];
    }

    // Drop auf sich selbst verbieten
    if (targetNode && [targetNode id] == draggedId) return CPDragOperationNone;

    // Drop in ein eigenes Kind verbieten (Zirkelschluss)
    var draggedNode = [self findNodeById:draggedId inNodes:_rootNodes];
    if (draggedNode && targetNode && [draggedNode hasDescendantWithId:[targetNode id]]) {
        return CPDragOperationNone;
    }

    return CPDragOperationMove;
}

- (BOOL)outlineView:(CPOutlineView)ov acceptDrop:(id)info item:(id)targetItem childIndex:(CPInteger)childIndex
{
    var pboard = [info draggingPasteboard];
    var draggedIdStr = [pboard stringForType:PromptDragType];
    if (!draggedIdStr) return NO;

    var draggedId = parseInt(draggedIdStr, 10);
    var targetNode = targetItem;
    if (targetItem && [targetItem respondsToSelector:@selector(representedObject)]) {
        targetNode = [targetItem representedObject];
    }

    var newParentId = targetNode ? [targetNode id] : null;
    var insertIndex = (childIndex < 0) ? 0 : childIndex;

    var payload = {
        "id": draggedId,
        "parent_id": newParentId,
        "index": insertIndex
    };

    var request = [CPURLRequest requestWithURL:@"/api/prompts/reorder"];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setHTTPBody:JSON.stringify(payload)];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
     {
        if (!error) {
            [self loadPromptTreeSelectingNodeId:draggedId];
        }
    }];

    return YES;
}

- (PromptNode)findNodeById:(id)anId inNodes:(CPArray)nodes
{
    for (var i = 0; i < [nodes count]; i++)
    {
        var n = [nodes objectAtIndex:i];
        if ([n id] == anId) return n;
        var found = [self findNodeById:anId inNodes:[n children]];
        if (found) return found;
    }
    return nil;
}

// --------------------------------------------------------------------------------
// Native Drag & Drop Konfiguration für den Upload Button
// --------------------------------------------------------------------------------

- (void)setupUploadButtonDragAndDrop
{
    setTimeout(function() {
        var btn = _uploadTemplateBtn;
        if (!btn) return;

        var domElement = btn._DOMElement;
        if (domElement) {
            var disableChildPointerEvents = function() {
                var children = domElement.getElementsByTagName('*');
                for (var i = 0; i < children.length; i++) {
                    children[i].style.pointerEvents = "none";
                }
            };

            disableChildPointerEvents();
            var dragCounter = 0;

            domElement.addEventListener("dragenter", function(e) {
                if (![btn isEnabled]) return;
                e.preventDefault();
                dragCounter++;

                if (dragCounter === 1) {
                    disableChildPointerEvents();
                    [btn setTitle:@"PDF hier ablegen!"];
                    domElement.style.outline = "2px dashed #0076FF";
                    domElement.style.outlineOffset = "-3px";
                    domElement.style.backgroundColor = "#E6F0FF";
                }
            });

            domElement.addEventListener("dragover", function(e) {
                if (![btn isEnabled]) return;
                e.preventDefault();
                e.dataTransfer.dropEffect = "copy";
            });

            domElement.addEventListener("dragleave", function(e) {
                if (![btn isEnabled]) return;
                e.preventDefault();
                dragCounter--;

                if (dragCounter <= 0) {
                    dragCounter = 0;
                    [btn setTitle:@"PDF hochladen (oder ziehen)"];
                    domElement.style.outline = "";
                    domElement.style.outlineOffset = "";
                    domElement.style.backgroundColor = "";
                }
            });

            domElement.addEventListener("drop", function(e) {
                if (![btn isEnabled]) return;
                e.preventDefault();
                dragCounter = 0;
                [btn setTitle:@"PDF hochladen (oder ziehen)"];
                domElement.style.outline = "";
                domElement.style.outlineOffset = "";
                domElement.style.backgroundColor = "";

                var files = e.dataTransfer.files;
                if (files && files.length > 0) {
                    var file = files[0];
                    if (file.name.toLowerCase().endsWith(".pdf")) {
                        [self uploadTemplateFile:file];
                    } else {
                        alert("Bitte nur PDF-Dateien hochladen.");
                    }
                }
            });
        }
    }, 200);
}

// --------------------------------------------------------------------------------
// Tree Laden & Selektion
// --------------------------------------------------------------------------------

- (void)loadPromptTree
{
    [self loadPromptTreeSelectingNodeId:nil];
}

- (void)loadPromptTreeSelectingNodeId:(id)targetSelectId
{
    var request = [CPURLRequest requestWithURL:@"/api/prompts/tree"];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
     {
        if (error) {
            console.error("Fehler beim Laden des Prompt-Baums:", error);
            return;
        }

        try {
            var rawList = JSON.parse(data);
            var parsedRoots = [CPMutableArray array];
            for (var i = 0; i < rawList.length; i++) {
                var node = [[PromptNode alloc] initWithDict:rawList[i]];
                [parsedRoots addObject:node];
            }

            _rootNodes = parsedRoots;
            [treeController setContent:_rootNodes];
            [_outlineView reloadData];

            setTimeout(function() {
                var arranged = [treeController arrangedObjects];
                if (arranged) {
                    var expandAll = function(item) {
                        [_outlineView expandItem:item];
                        var children = [item childNodes];
                        if (children) {
                            for (var c = 0; c < [children count]; c++) {
                                expandAll([children objectAtIndex:c]);
                            }
                        }
                    };

                    var rootChildren = [arranged childNodes];
                    for (var i = 0; i < [rootChildren count]; i++) {
                        expandAll([rootChildren objectAtIndex:i]);
                    }

                    var targetRow = -1;
                    var totalRows = [_outlineView numberOfRows];

                    if (targetSelectId !== nil && targetSelectId !== undefined) {
                        for (var r = 0; r < totalRows; r++) {
                            var item = [_outlineView itemAtRow:r];
                            var node = item;
                            if (item && [item respondsToSelector:@selector(representedObject)]) {
                                node = [item representedObject];
                            }
                            if (node && [node id] == targetSelectId) {
                                targetRow = r;
                                break;
                            }
                        }
                    }

                    if (targetRow !== -1) {
                        [_outlineView selectRowIndexes:[CPIndexSet indexSetWithIndex:targetRow] byExtendingSelection:NO];
                        [_outlineView scrollRowToVisible:targetRow];
                    } else if (totalRows > 0 && [_outlineView selectedRow] === -1) {
                        [_outlineView selectRowIndexes:[CPIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
                    }
                }
            }, 60);
        } catch (e) {
            console.error("JSON Parse Exception:", e);
        }
    }];
}

// --------------------------------------------------------------------------------
// Flush & Selektionswechsel
// --------------------------------------------------------------------------------

- (void)flushActiveEditsToCurrentNode
{
    if (_activeSelectedNode && !_isProgrammaticUpdate)
    {
        var titleVal = [_titleField stringValue];
        if (titleVal !== undefined && titleVal !== null) {
            [_activeSelectedNode setTitle:titleVal];
            [_activeSelectedNode setName:titleVal];
        }

        var promptVal = [_promptTextView string];
        if (promptVal !== undefined && promptVal !== null) {
            [_activeSelectedNode setPrompt_text:promptVal];
        }

        var selectedIndex = [_formatPopUp indexOfSelectedItem];
        var format = (selectedIndex === 1) ? @"pdf_fill" : ((selectedIndex === 2) ? @"latex" : @"markdown");
        [_activeSelectedNode setOutput_format:format];

        [self saveNodeToBackend:_activeSelectedNode];
    }
}

- (void)outlineViewSelectionDidChange:(CPNotification)aNotification
{
    [self flushActiveEditsToCurrentNode];

    var selectedRow = [_outlineView selectedRow];
    if (selectedRow === -1) {
        _activeSelectedNode = nil;
        [self updateDetailFormWithNode:nil];
        return;
    }

    var item = [_outlineView itemAtRow:selectedRow];
    var node = item;
    if (item && [item respondsToSelector:@selector(representedObject)]) {
        node = [item representedObject];
    }

    _activeSelectedNode = node;
    [self updateDetailFormWithNode:_activeSelectedNode];
}

- (void)updateDetailFormWithNode:(PromptNode)node
{
    _isProgrammaticUpdate = YES;

    var hasNode = (node !== nil && node !== undefined);

    [_titleField setEnabled:hasNode];
    [_formatPopUp setEnabled:hasNode];
    [_promptTextView setEditable:hasNode];

    if (!hasNode) {
        [_titleField setStringValue:@""];
        [_promptTextView setString:@""];
        [_formatPopUp selectItemAtIndex:0];
        [self applyTemplateControlsStateForNode:nil format:@"markdown"];
        _isProgrammaticUpdate = NO;
        return;
    }

    [_titleField setStringValue:[node title] || @""];
    [_promptTextView setString:[node prompt_text] || @""];

    var format = [node output_format] || @"markdown";

    if ([format isEqualToString:@"pdf_fill"]) {
        [_formatPopUp selectItemWithTitle:@"PDF-Ausfüll-Tool"];
    } else if ([format isEqualToString:@"latex"]) {
        [_formatPopUp selectItemWithTitle:@"PDF (via LaTeX)"]; // Exakter Titel aus gui.gsmarkup
    } else {
        [_formatPopUp selectItemWithTitle:@"Markdown"];
    }

    [self applyTemplateControlsStateForNode:node format:format];

    _isProgrammaticUpdate = NO;
}

- (void)applyTemplateControlsStateForNode:(PromptNode)node format:(CPString)format
{
    var hasNode = (node !== nil && node !== undefined);
    var isPdf = [format isEqualToString:@"pdf_fill"];
    var canUpload = hasNode && isPdf;

    [_uploadTemplateBtn setEnabled:canUpload];

    if (_uploadTemplateBtn._DOMElement) {
        _uploadTemplateBtn._DOMElement.style.opacity = canUpload ? "1.0" : "0.45";
        _uploadTemplateBtn._DOMElement.style.cursor = canUpload ? "pointer" : "default";
    }

    if (!hasNode) {
        if (_templateIconLabel) [_templateIconLabel setHidden:YES];
        [_templateNameLabel setStringValue:@"Kein Node ausgewählt."];
        [_downloadTemplateBtn setEnabled:NO];
        if (_deleteTemplateBtn) [_deleteTemplateBtn setEnabled:NO];
    }
    else if (!isPdf) {
        if (_templateIconLabel) [_templateIconLabel setHidden:YES];
        [_templateNameLabel setStringValue:@"Nur bei Format 'PDF-Ausfüll-Tool' verfügbar."];
        [_downloadTemplateBtn setEnabled:NO];
        if (_deleteTemplateBtn) [_deleteTemplateBtn setEnabled:NO];
    }
    else if ([node has_template]) {
        if (_templateIconLabel) [_templateIconLabel setHidden:NO];
        [_templateNameLabel setStringValue:[node template_name] || @"Template hinterlegt"];
        [_downloadTemplateBtn setEnabled:YES];
        if (_deleteTemplateBtn) [_deleteTemplateBtn setEnabled:YES];
    }
    else {
        if (_templateIconLabel) [_templateIconLabel setHidden:YES];
        [_templateNameLabel setStringValue:@"Kein Template hochgeladen."];
        [_downloadTemplateBtn setEnabled:NO];
        if (_deleteTemplateBtn) [_deleteTemplateBtn setEnabled:NO];
    }
}

// --------------------------------------------------------------------------------
// Live-Synchronisation
// --------------------------------------------------------------------------------

- (void)controlTextDidChange:(CPNotification)aNotification
{
    if (_isProgrammaticUpdate || !_activeSelectedNode) return;

    var newTitle = [_titleField stringValue];
    [_activeSelectedNode setTitle:newTitle];
    [_activeSelectedNode setName:newTitle];

    [_outlineView reloadData];
    [self scheduleAutoSave];
}

- (void)textDidChange:(CPNotification)aNotification
{
    if (_isProgrammaticUpdate || !_activeSelectedNode) return;

    [_activeSelectedNode setPrompt_text:[_promptTextView string]];
    [self scheduleAutoSave];
}

- (void)titleFieldDidChange:(id)sender
{
    [self controlTextDidChange:nil];
    [self saveCurrentPromptConfig:sender];
}

- (void)formatSelectionChanged:(id)sender
{
    if (_isProgrammaticUpdate || !_activeSelectedNode) return;

    var selectedIndex = [_formatPopUp indexOfSelectedItem];
    var format = @"markdown";
    if (selectedIndex === 1) format = @"pdf_fill";
    if (selectedIndex === 2) format = @"latex";

    [_activeSelectedNode setOutput_format:format];
    [self applyTemplateControlsStateForNode:_activeSelectedNode format:format];
    [self saveCurrentPromptConfig:sender];
}

// --------------------------------------------------------------------------------
// Auto-Save
// --------------------------------------------------------------------------------

- (void)scheduleAutoSave
{
    if (_autoSaveTimer) {
        clearTimeout(_autoSaveTimer);
        _autoSaveTimer = nil;
    }

    var nodeRef = _activeSelectedNode;

    _autoSaveTimer = setTimeout(function() {
        if (nodeRef) {
            [self saveNodeToBackend:nodeRef];
        }
    }, 500);
}

- (void)saveNodeToBackend:(PromptNode)node
{
    if (!node || ![node id]) return;

    var payload = {
        "title": [node title],
        "prompt_text": [node prompt_text],
        "output_format": [node output_format]
    };

    var request = [CPURLRequest requestWithURL:@"/api/prompts/" + [node id]];
    [request setHTTPMethod:@"PUT"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setHTTPBody:JSON.stringify(payload)];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
     {
        if (error) {
            console.error("AutoSave Fehler:", error);
        }
    }];
}

- (void)saveCurrentPromptConfig:(id)sender
{
    if (!_activeSelectedNode) return;
    [self flushActiveEditsToCurrentNode];
    [_outlineView reloadData];
}

// --------------------------------------------------------------------------------
// CRUD Aktionen
// --------------------------------------------------------------------------------

- (void)addNewPrompt:(id)sender
{
    [self flushActiveEditsToCurrentNode];

    var parentId = _activeSelectedNode ? [_activeSelectedNode id] : null;

    var payload = {
        "parent_id": parentId,
        "title": @"Neuer Prompt",
        "prompt_text": @"Erstelle eine Zusammenfassung:\n\n{INPUT}",
        "output_format": @"markdown"
    };

    var request = [CPURLRequest requestWithURL:@"/api/prompts"];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setHTTPBody:JSON.stringify(payload)];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
     {
        if (!error && data) {
            var newId = nil;
            try {
                var res = JSON.parse(data);
                if (res && res.id !== undefined) {
                    newId = res.id;
                } else if (typeof res === "number") {
                    newId = res;
                }
            } catch (e) {
                console.error("Fehler beim Parsen der Server-Antwort:", e);
            }
            [self loadPromptTreeSelectingNodeId:newId];
        } else {
            [self loadPromptTree];
        }
    }];
}

- (void)deleteSelectedPrompt:(id)sender
{
    if (!_activeSelectedNode) return;

    var promptId = [_activeSelectedNode id];
    _activeSelectedNode = nil;

    var request = [CPURLRequest requestWithURL:@"/api/prompts/" + promptId];
    [request setHTTPMethod:@"DELETE"];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
     {
        if (!error) {
            [self loadPromptTree];
        }
    }];
}

// --------------------------------------------------------------------------------
// Upload / Download / Löschen
// --------------------------------------------------------------------------------

- (void)triggerNativeUploadAction:(id)sender
{
    if (!_activeSelectedNode) {
        alert("Bitte wählen Sie zuerst links einen Prompt aus.");
        return;
    }

    if ([_activeSelectedNode output_format] !== @"pdf_fill") {
        alert("Ein Template kann nur für das Ausgabeformat 'PDF-Ausfüll-Tool' hinterlegt werden.");
        return;
    }

    var input = document.createElement('input');
    input.type = 'file';
    input.accept = '.pdf';

    input.onchange = function(event) {
        var files = event.target.files;
        if (files && files.length > 0) {
            [self uploadTemplateFile:files[0]];
        }
    };
    input.click();
}

- (void)uploadTemplateFile:(id)file
{
    if (!_activeSelectedNode) {
        alert("Bitte wählen Sie zuerst links einen Prompt aus.");
        return;
    }

    var node = _activeSelectedNode;

    [_uploadTemplateBtn setEnabled:NO];
    [_uploadTemplateBtn setTitle:@"Übertrage PDF..."];
    if (_templateIconLabel) [_templateIconLabel setHidden:YES];
    [_templateNameLabel setStringValue:@"Lade " + file.name + " hoch..."];

    var formData = new FormData();
    formData.append('file', file);

    fetch('/api/prompts/' + [node id] + '/upload_template', {
        method: 'POST',
        body: formData
    })
    .then(function(response) {
        if (!response.ok) {
            throw new Error("HTTP Status " + response.status);
        }
        return response.json();
    })
    .then(function(data) {
        [_uploadTemplateBtn setTitle:@"PDF hochladen (oder ziehen)"];

        if (data && data.success) {
            [node setHas_template:YES];
            [node setTemplate_name:file.name];
            [self updateDetailFormWithNode:node];
        } else {
            alert("Upload fehlgeschlagen: " + (data.error || "Unbekannter Fehler"));
            [self updateDetailFormWithNode:node];
        }
        [[CPRunLoop currentRunLoop] limitDateForMode:CPDefaultRunLoopMode];
    })
    .catch(function(error) {
        [_uploadTemplateBtn setTitle:@"PDF hochladen (oder ziehen)"];
        [_templateNameLabel setStringValue:@"Fehler beim Upload."];
        [self updateDetailFormWithNode:node];
        alert("Fehler beim Hochladen der Datei: " + error.message);
    });
}

- (void)downloadTemplateAction:(id)sender
{
    if (!_activeSelectedNode || ![_activeSelectedNode has_template]) return;
    window.open('/api/prompts/' + [_activeSelectedNode id] + '/download_template', '_blank');
}

- (void)deleteTemplateAction:(id)sender
{
    if (!_activeSelectedNode || ![_activeSelectedNode has_template]) return;

    var node = _activeSelectedNode;

    var request = [CPURLRequest requestWithURL:@"/api/prompts/" + [node id] + "/template"];
    [request setHTTPMethod:@"DELETE"];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
     {
        [node setHas_template:NO];
        [node setTemplate_name:@""];
        [self updateDetailFormWithNode:node];
        [self scheduleAutoSave];
    }];
}

- (BOOL)outlineView:(CPOutlineView)anOutlineView shouldEditTableColumn:(CPTableColumn)aTableColumn item:(id)anItem
{
    return YES;
}

// Wird aufgerufen, sobald der Inline-Edit beendet wurde
- (void)nodeDidInlineEdit:(PromptNode)node
{
    // Falls das gerade editierte Element auch rechts im Detailformular ausgewählt ist:
    if (_activeSelectedNode === node)
    {
        _isProgrammaticUpdate = YES;
        [_titleField setStringValue:[node title] || @""];
        _isProgrammaticUpdate = NO;
    }

    // Speichert den neuen Titel sofort an die Datenbank
    [self saveNodeToBackend:node];
}

// --------------------------------------------------------------------------------
// Prompt Ausführen (LLM Inferenz)
// --------------------------------------------------------------------------------

- (void)runPromptAction:(id)sender
{
    [self flushActiveEditsToCurrentNode];

    if (!_activeSelectedNode) {
        alert("Bitte wählen Sie links im Baum zuerst einen Prompt aus.");
        return;
    }

    var inputText = [_applyInputTextView string];
    if (!inputText || [inputText length] === 0) {
        alert("Bitte geben Sie zuerst Text in das Eingabefeld ein.");
        return;
    }

    [_runButton setEnabled:NO];
    [_runButton setTitle:@"⏳ LLM generiert Antwort..."];

    var payload = {
        "prompt_id": [_activeSelectedNode id],
        "input_text": inputText,
        "model": selectedModel
    };

    var request = [CPURLRequest requestWithURL:@"/api/prompts/run"
                                   cachePolicy:CPURLRequestUseProtocolCachePolicy
                               timeoutInterval:3600.0];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setHTTPBody:JSON.stringify(payload)];

    [CPURLConnection sendAsynchronousRequest:request
                                       queue:[CPOperationQueue mainQueue]
                           completionHandler:function(response, data, error)
     {
        [_runButton setEnabled:YES];
        [_runButton setTitle:@"⚡ Prompt durch LLM ausführen"];

        if (!error && data) {
            var res = JSON.parse(data);
            if (res.error) {
                alert("Fehler bei der Ausführung: " + res.error);
                return;
            }

            if (res.type === "markdown") {
                [self showMarkdownPopoverWithText:res.content relativeToView:_runButton];
            } else if (res.type === "download") {
                [self triggerBase64Download:res.base64_data filename:res.filename mimeType:res.mime];
            }
        } else {
            alert("Verbindungsfehler zum LLM-Dienst: " + (error ? [error description] : 'Timeout'));
        }
    }];
}

- (void)triggerBase64Download:(CPString)base64Data filename:(CPString)filename mimeType:(CPString)mimeType
{
    var link = document.createElement('a');
    link.href = 'data:' + mimeType + ';base64,' + base64Data;
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
}

// --------------------------------------------------------------------------------
// Ergebnis Popover mit TabView (Rich-Text / Markdown Quelltext)
// --------------------------------------------------------------------------------

- (void)showMarkdownPopoverWithText:(CPString)markdownText relativeToView:(CPView)targetView
{
    _currentOutputMarkdown = markdownText || @"";

    if (!_markdownPopover) {
        _markdownPopover = [[CPPopover alloc] init];
        [_markdownPopover setBehavior:CPPopoverBehaviorTransient];
        [_markdownPopover setAppearance:CPPopoverAppearanceMinimal];
        [_markdownPopover setAnimates:YES];

        var container = [[CPView alloc] initWithFrame:CGRectMake(0, 0, 720, 520)];

        // TabView initialisieren
        _popoverTabView = [[CPTabView alloc] initWithFrame:CGRectMake(15, 15, 690, 445)];
        [_popoverTabView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];

        // 1. Tab: Rich-Text (Formatiert)
        var richTabItem = [[CPTabViewItem alloc] initWithIdentifier:@"richTextTab"];
        [richTabItem setLabel:@"Rich-Text"];

        var richScrollView = [[CPScrollView alloc] initWithFrame:CGRectMake(0, 0, 690, 410)];
        [richScrollView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
        [richScrollView setHasVerticalScroller:YES];
        [richScrollView setHasHorizontalScroller:NO];

        _popoverRichTextView = [[CPTextView alloc] initWithFrame:[richScrollView bounds]];
        [_popoverRichTextView setEditable:NO];
        [_popoverRichTextView setSelectable:YES];
        [_popoverRichTextView setAutoresizingMask:CPViewWidthSizable];
        [richScrollView setDocumentView:_popoverRichTextView];
        [richTabItem setView:richScrollView];
        [_popoverTabView addTabViewItem:richTabItem];

        // 2. Tab: Markdown Quelltext
        var mdTabItem = [[CPTabViewItem alloc] initWithIdentifier:@"markdownTab"];
        [mdTabItem setLabel:@"Markdown (Quelltext)"];

        var mdScrollView = [[CPScrollView alloc] initWithFrame:CGRectMake(0, 0, 690, 410)];
        [mdScrollView setAutoresizingMask:CPViewWidthSizable | CPViewHeightSizable];
        [mdScrollView setHasVerticalScroller:YES];
        [mdScrollView setHasHorizontalScroller:NO];

        _popoverMarkdownTextView = [[CPTextView alloc] initWithFrame:[mdScrollView bounds]];
        [_popoverMarkdownTextView setEditable:NO];
        [_popoverMarkdownTextView setSelectable:YES];
        [_popoverMarkdownTextView setFont:[CPFont fontWithName:@"Monaco" size:12.0]];
        [_popoverMarkdownTextView setAutoresizingMask:CPViewWidthSizable];
        [mdScrollView setDocumentView:_popoverMarkdownTextView];
        [mdTabItem setView:mdScrollView];
        [_popoverTabView addTabViewItem:mdTabItem];

        [container addSubview:_popoverTabView];

        // Copy Button unten
        var copyBtn = [[CPButton alloc] initWithFrame:CGRectMake(15, 470, 200, 32)];
        [copyBtn setTitle:@"Markdown kopieren"];
        [copyBtn setTarget:self];
        [copyBtn setAction:@selector(copyMarkdownToClipboard:)];
        [container addSubview:copyBtn];

        var vc = [[CPViewController alloc] init];
        [vc setView:container];
        [_markdownPopover setContentViewController:vc];
    }

    // Markdown in roher Form setzen
    [_popoverMarkdownTextView setString:_currentOutputMarkdown];

    // Markdown parsen und formatiert in den Rich-Text Tab setzen
    var attributedString = [CPMarkdownParser attributedStringFromMarkdown:_currentOutputMarkdown];
    [_popoverRichTextView setString:attributedString];

    // Standardmäßig den Rich-Text Tab aktivieren
    [_popoverTabView selectFirstTabViewItem:self];

    [_markdownPopover showRelativeToRect:[targetView bounds] ofView:targetView preferredEdge:CPMaxYEdge];
}

- (void)copyMarkdownToClipboard:(id)sender
{
    var text = _currentOutputMarkdown;
    if (!text || [text length] === 0) {
        text = [_popoverMarkdownTextView string];
    }

    navigator.clipboard.writeText(text).then(function() {
        alert("Markdown erfolgreich in die Zwischenablage kopiert!");
    });
}

@end
