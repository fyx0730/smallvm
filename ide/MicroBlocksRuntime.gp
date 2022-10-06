// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

// Copyright 2019 John Maloney, Bernat Romagosa, and Jens Mönig

// MicroBlocksRuntime.gp - Runtime support for MicroBlocks
// John Maloney, April, 2017

to smallRuntime aScripter {
	if (isNil (global 'smallRuntime')) {
		setGlobal 'smallRuntime' (initialize (new 'SmallRuntime') aScripter)
	}
	return (global 'smallRuntime')
}

defineClass SmallRuntime ideVersion latestVMVersion scripter chunkIDs chunkRunning msgDict portName port connectionStartTime lastScanMSecs pingSentMSecs lastPingRecvMSecs recvBuf oldVarNames vmVersion boardType lastBoardDrives loggedData loggedDataNext loggedDataCount vmInstallMSecs disconnected crcDict lastRcvMSecs readFromBoard decompiler decompilerStatus blockForResultImage fileTransferMsgs fileTransferProgress fileTransfer firmwareInstallTimer

method scripter SmallRuntime { return scripter }

method initialize SmallRuntime aScripter {
	scripter = aScripter
	chunkIDs = (dictionary)
	readFromBoard = false
	clearLoggedData this
	return this
}

method evalOnBoard SmallRuntime aBlock showBytes {
	if (isNil showBytes) { showBytes = false }
	if showBytes {
		bytes = (chunkBytesFor this aBlock)
		print (join 'Bytes for chunk ' id ':') bytes
		print '----------'
		return
	}
	if ('not connected' == (updateConnection this)) {
		showError (morph aBlock) 'Board not connected'
		return
	}
	step scripter // save script changes if needed
	if (isNil (ownerThatIsA (morph aBlock) 'ScriptEditor')) {
		// running a block from the palette, not included in saveAllChunks
		saveChunk this aBlock
	}
	runChunk this (lookupChunkID this aBlock)
}

method stopRunningBlock SmallRuntime aBlock {
	if (isRunning this aBlock) {
		stopRunningChunk this (lookupChunkID this aBlock)
	}
}

method chunkTypeFor SmallRuntime aBlockOrFunction {
	if (isClass aBlockOrFunction 'Function') { return 3 }
	if (and
		(isClass aBlockOrFunction 'Block')
		(isPrototypeHat aBlockOrFunction)) {
			return 3
	}

	expr = (expression aBlockOrFunction)
	op = (primName expr)
	if ('whenStarted' == op) { return 4 }
	if ('whenCondition' == op) { return 5 }
	if ('whenBroadcastReceived' == op) { return 6 }
	if ('whenButtonPressed' == op) {
		button = (first (argList expr))
		if ('A' == button) { return 7 }
		if ('B' == button) { return 8 }
		return 9 // A+B
	}
	if (isClass expr 'Command') { return 1 }
	if (isClass expr 'Reporter') { return 2 }

	error 'Unexpected argument to chunkTypeFor'
}

method chunkBytesFor SmallRuntime aBlockOrFunction {
	if (isClass aBlockOrFunction 'String') { // look up function by name
		aBlockOrFunction = (functionNamed (project scripter) aBlockOrFunction)
		if (isNil aBlockOrFunction) { return (list) } // unknown function
	}
	compiler = (initialize (new 'SmallCompiler'))
	code = (instructionsFor compiler aBlockOrFunction)
	bytes = (list)
	for item code {
		if (isClass item 'Array') {
			addBytesForInstructionTo compiler item bytes
		} (isClass item 'Integer') {
			addBytesForIntegerLiteralTo compiler item bytes
		} (isClass item 'String') {
			addBytesForStringLiteral compiler item bytes
		} else {
			error 'Instruction must be an Array or String:' item
		}
	}
	return bytes
}

method showInstructions SmallRuntime aBlock {
	// Display the instructions for the given stack.

	compiler = (initialize (new 'SmallCompiler'))
	code = (instructionsFor compiler (topBlock aBlock))
	result = (list)
	for item code {
		if (not (isClass item 'Array')) {
			addWithLineNum this result (toString item)
		} ('pushImmediate' == (first item)) {
			arg = (at item 2)
			if (1 == (arg & 1)) {
				arg = (arg >> 1) // decode integer
				if (arg >= 4194304) { arg = (arg - 8388608) }
			} (0 == arg) {
				arg = false
			} (4 == arg) {
				arg = true
			}
			addWithLineNum this result (join 'pushImmediate ' arg)
		} ('pushBigImmediate' == (first item)) {
			addWithLineNum this result 'pushBigImmediate' // don't show arg count; could be confusing
		} ('callFunction' == (first item)) {
			arg = (at item 2)
			calledChunkID = ((arg >> 8) & 255)
			argCount = (arg & 255)
			addWithLineNum this result (join 'callFunction ' calledChunkID ' ' argCount)
		} (not (isLetter (at (first item) 1))) { // operator; don't show arg count
			addWithLineNum this result (toString (first item))
		} else {
			// instruction (an array of form <cmd> <args...>)
			instr = ''
			for s item { instr = (join instr s ' ') }
			addWithLineNum this result instr item
		}
	}
	ws = (openWorkspace (global 'page') (joinStrings result (newline)))
	setTitle ws 'Instructions'
	setFont ws 'Arial' (16 * (global 'scale'))
	setExtent (morph ws) (220 * (global 'scale')) (400 * (global 'scale'))
	fixLayout ws
}

method addWithLineNum SmallRuntime aList instruction items {
	currentLine = ((count aList) + 1)
	targetLine = ''
	if (and
		(notNil items)
		(isOneOf (first items)
			'pushLiteral' 'jmp' 'jmpTrue' 'jmpFalse'
			'decrementAndJmp' 'callFunction' 'forLoop')) {
		offset = (toInteger (last items))
		targetLine = (join ' (line ' (+ currentLine 1 offset) ')')
	}
	add aList (join '' currentLine ' ' instruction targetLine)
}

method showCompiledBytes SmallRuntime aBlock {
	// Display the instruction bytes for the given stack.

	bytes = (chunkBytesFor this (topBlock aBlock))
	result = (list)
	add result (join '[' (count bytes) ' bytes]' (newline))
	for i (count bytes) {
		add result (toString (at bytes i))
		if (0 == (i % 4)) {
			add result (newline)
		} else {
			add result ' '
		}
	}
	if (and ((count result) > 0) ((newline) == (last result))) { removeLast result }
	ws = (openWorkspace (global 'page') (joinStrings result))
	setTitle ws 'Instruction Bytes'
	setFont ws 'Arial' (16 * (global 'scale'))
	setExtent (morph ws) (220 * (global 'scale')) (400 * (global 'scale'))
	fixLayout ws
}

method showCallTree SmallRuntime aBlock {
	proto = (editedPrototype aBlock)
	if (notNil proto) {
		if (isNil (function proto)) { return }
		funcName = (functionName (function proto))
	} else {
		funcName = (primName (expression aBlock))
	}

	allFunctions = (dictionary)
	for f (allFunctions (project scripter)) { atPut allFunctions (functionName f) f }

	result = (list)
	appendCallsForFunction this funcName result '' allFunctions (array funcName)

	ws = (openWorkspace (global 'page') (joinStrings result (newline)))
	setTitle ws 'Call Tree'
	setFont ws 'Arial' (16 * (global 'scale'))
	setExtent (morph ws) (400 * (global 'scale')) (400 * (global 'scale'))
	fixLayout ws
}

method appendCallsForFunction SmallRuntime funcName result indent allFunctions callers {
	func = (at allFunctions funcName)

	argCount = (count (argNames func))
	localCount = (count (localNames func))
	stackWords = (+ 3 argCount localCount)
	info = ''
	if (or (argCount > 0) (localCount > 0)) {
		info = (join info ' (')
		if (argCount > 0) {
			info = (join info argCount ' arg')
			if (argCount > 1) { info = (join info 's') }
			if (localCount > 0) { info = (join info ', ') }
		}
		if (localCount > 0) {
			info = (join info localCount ' local')
			if (localCount > 1) { info = (join info 's') }
		}
		info = (join info ')')
	}
	add result (join indent funcName info ' ' stackWords)
	indent = (join '   ' indent)

	if (isNil (cmdList func)) { return }

	processed = (dictionary)
	for cmd (allBlocks (cmdList func)) {
		op = (primName cmd)
		if (and (contains allFunctions op) (not (contains processed op))) {
			if (contains callers op) {
				add result (join indent '   ' funcName ' [recursive]')
			} else {
				appendCallsForFunction this op result indent allFunctions (copyWith callers op)
			}
			add processed op
		}
	}
}

// Decompiler tests

method testDecompiler SmallRuntime aBlock {
	topBlock = (topBlock aBlock)
	gpCode = (decompileBytecodes -1 (chunkTypeFor this topBlock) (chunkBytesFor this topBlock))
	showCodeInHand this gpCode
}

method showCodeInHand SmallRuntime gpCode {
	if (isClass gpCode 'Function') {
		block = (scriptForFunction gpCode)
	} (or (isClass gpCode 'Command') (isClass gpCode 'Reporter')) {
		block = (toBlock gpCode)
	} else {
		// decompiler didn't return something that can be represented as blocks
		return
	}
	grab (hand (global 'page')) block
	fixBlockColor block
}

method compileAndDecompile SmallRuntime aBlockOrFunction {
	if (isClass aBlockOrFunction 'Function') {
		chunkID = (first (at chunkIDs (functionName aBlockOrFunction)))
	}
	chunkType = (chunkTypeFor this aBlockOrFunction)
	bytecodes1 = (chunkBytesFor this aBlockOrFunction)
	gpCode = (decompileBytecodes chunkID chunkType bytecodes1)
	bytecodes2 = (chunkBytesFor this gpCode)
	if (bytecodes1 == bytecodes2) {
		if ((count bytecodes1) > 750) {
			print 'ok chunkType:' chunkType 'bytes:' (count bytecodes1)
		}
	} else {
		print 'FAILED! chunkType:' chunkType 'bytes in:' (count bytecodes1) 'bytes out' (count bytecodes2)
	}
}

method decompileAll SmallRuntime {
	// Called by dev menu 'decompile all' for testing.

	decompileAllExamples this
}

method decompileAllExamples SmallRuntime {
	for fn (listEmbeddedFiles) {
		if (beginsWith fn 'Examples') {
			print fn
			openProjectFromFile (findMicroBlocksEditor) (join '//' fn)
			decompileAllInProject this
		}
	}
}

method decompileAllInProject SmallRuntime {
	assignFunctionIDs this
	for aFunction (allFunctions (project scripter)) {
		compileAndDecompile this aFunction
	}
	for aBlock (sortedScripts (scriptEditor scripter)) {
		if (not (isPrototypeHat aBlock)) { // functions are handled above
			compileAndDecompile this aBlock
		}
	}
}

method analyzeAllExamples SmallRuntime {
	for fn (listEmbeddedFiles) {
		if (beginsWith fn 'Examples') {
			print fn
			openProjectFromFile (findMicroBlocksEditor) (join '//' fn)
			analyzeProject this
		}
	}
}

method analyzeProject SmallRuntime {
	totalBytes = 0
	assignFunctionIDs this
	for aFunction (allFunctions (project scripter)) {
		byteCount = (count (chunkBytesFor this aFunction))
		if (byteCount > 700) { print ' ' (functionName aFunction) byteCount }
		totalBytes += byteCount
	}
	for aBlock (sortedScripts (scriptEditor scripter)) {
		if (not (isPrototypeHat aBlock)) { // functions are handled above
			byteCount = (count (chunkBytesFor this aBlock))
			if (byteCount > 700) { print '     script' byteCount }
			totalBytes += byteCount
		}
	}
	print '  Total:' totalBytes
	print '-----------'
}

// Decompiling

method readCodeFromNextBoardConnected SmallRuntime {
	readFromBoard = true
	disconnected = false
	if ('Browser' == (platform)) {
		// in browser, cannot add the spinner before user has clicked connect icon
		inform 'Plug in the board and click the USB icon to connect.'
		return
	}
	decompilerStatus = (localized 'Plug in the board.')
	spinner = (newSpinner (action 'decompilerStatus' (smallRuntime)) (action 'decompilerDone' (smallRuntime)))
	addPart (global 'page') spinner
}

method readCodeFromBoard SmallRuntime {
	decompiler = (newDecompiler)
	waitForPing this
	decompilerStatus = (localized 'Reading project from board...')

	if ('Browser' == (platform)) {
		prompter = (findMorph 'Prompter')
		if (notNil prompter) { destroy prompter } // remove the prompt to connect board

		if (not (canReplaceCurrentProject (findMicroBlocksEditor))) {
			return // uncommon: user started writing code before connecting the board
		}

		// in browser, spinner was not added earlier
		spinner = (newSpinner (action 'decompilerStatus' (smallRuntime)) (action 'decompilerDone' (smallRuntime)))
		addPart (global 'page') spinner
	}

	sendMsg this 'getVarNamesMsg'
	lastRcvMSecs = (msecsSinceStart)
	while (((msecsSinceStart) - lastRcvMSecs) < 100) {
		processMessages this
		waitMSecs 10
	}

	sendMsg this 'getAllCodeMsg'
	lastRcvMSecs = (msecsSinceStart)
	while (((msecsSinceStart) - lastRcvMSecs) < 2000) {
		processMessages this
		doOneCycle (global 'page')
		waitMSecs 10
	}
	if (isNil decompiler) { return } // decompilation was aborted

print 'Read' (count (getField decompiler 'vars')) 'vars' (count (getField decompiler 'chunks')) 'chunks'
	proj = (decompileProject decompiler)
	decompilerStatus = (localized 'Loading project...')
	doOneCycle (global 'page')
	installDecompiledProject this proj
	readFromBoard = false
	decompiler = nil
}

method decompilerDone SmallRuntime { return (and (isNil decompiler) (not readFromBoard)) }
method decompilerStatus SmallRuntime { return decompilerStatus }

method stopDecompilation SmallRuntime {
	readFromBoard = false
	spinnerM = (findMorph 'MicroBlocksSpinner')
	if (notNil spinnerM) { removeFromOwner spinnerM }

	if (notNil decompiler) {
		decompiler = nil
		clearBoardIfConnected this true
		stopAndSyncScripts this
	}
}

method waitForPing SmallRuntime {
	// Try to get a ping back from the board. Used to ensure that the board is responding.

	endMSecs = ((msecsSinceStart) + 1000)
	lastPingRecvMSecs = 0
	while (0 == lastPingRecvMSecs) {
		if ((msecsSinceStart) > endMSecs) { return } // no response within the timeout
		sendMsg this 'pingMsg'
		processMessages this
		waitMSecs 10
	}
}

method installDecompiledProject SmallRuntime proj {
	clearBoardIfConnected this true
	setProject scripter proj
	updateLibraryList scripter
	checkForNewerLibraryVersions (project scripter) true
	restoreScripts scripter // fix block colors
	cleanUp (scriptEditor scripter)
	saveAllChunks this
}

method receivedChunk SmallRuntime chunkID chunkType bytecodes {
	lastRcvMSecs = (msecsSinceStart)
	if (isEmpty bytecodes) {
		print 'truncated chunk!' chunkID chunkType (count bytecodes) // shouldn't happen
		return
	}
	if (notNil decompiler) {
		addChunk decompiler chunkID chunkType bytecodes
	}
}

method receivedVarName SmallRuntime varID varName byteCount {
	lastRcvMSecs = (msecsSinceStart)
	if (notNil decompiler) {
		addVar decompiler varID varName
	}
}

// HTTP server support

method readVarsFromBoard SmallRuntime client {
	if (notNil decompiler) { return }

	// pretend to be a decompiler to collect variable names
	decompiler = client
	waitForPing this
	sendMsg this 'getVarNamesMsg'
	lastRcvMSecs = (msecsSinceStart)
	while (((msecsSinceStart) - lastRcvMSecs) < 50) {
		processMessages this
		waitMSecs 10
	}
	// clear decompiler
	decompiler = nil
}


// chunk management

method syncScripts SmallRuntime {
	// Called by scripter when anything changes.

	if (isNil port) { return }

	// force re-save of any functions in the scripting area
	for aBlock (sortedScripts (scriptEditor scripter)) {
		if (isPrototypeHat aBlock) {
			fName = (functionName (function (editedPrototype aBlock)))
			entry = (at chunkIDs fName nil)
			if (notNil entry) {
				// record that function is in scripting area so must be checked for changes
				atPut entry 5 true
			}
		}
	}

	saveAllChunks this
}

method lookupChunkID SmallRuntime key {
	// If the given block or function name has been assigned a chunkID, return it.
	// Otherwise, return nil.

	entry = (at chunkIDs key nil)
	if (isNil entry) { return nil }
	return (first entry)
}

method removeObsoleteChunks SmallRuntime {
	// Remove obsolete chunks. Chunks become obsolete when they are deleted or inserted into
	// a script so they are no longer a stand-alone chunk. Functions become obsolete when
	// they are deleted or the library containing them is deleted.

	for k (keys chunkIDs) {
		if (isClass k 'Block') {
			owner = (owner (morph k))
			isObsolete = (or
				(isNil owner)
				(isNil (handler owner))
				(not (isAnyClass (handler owner) 'Hand' 'ScriptEditor' 'BlocksPalette')))
			if isObsolete {
				deleteChunkForBlock this k
			}
		} (isClass k 'String') {
			if (isNil (functionNamed (project scripter) k)) {
				remove chunkIDs k
			}
		}
	}
}

method unusedChunkID SmallRuntime {
	// Return an unused chunkID.

	inUse = (dictionary)
	for entry (values chunkIDs) {
		add inUse (first entry) // the chunk ID is first element of entry
	}
	for i 256 {
		id = (i - 1)
		if (not (contains inUse id)) { return id }
	}
	error 'Too many code chunks (functions and scripts). Max is 256).'
}

method ensureChunkIdFor SmallRuntime aBlock {
	// Return the chunkID for the given block. Functions are handled by assignFunctionIDs.
	// If necessary, register the block in the chunkIDs dictionary.

	entry = (at chunkIDs aBlock nil)
	if (isNil entry) {
		id = (unusedChunkID this)
		entry = (array id nil (chunkTypeFor this aBlock) '' false)
		atPut chunkIDs aBlock entry // block -> (<id>, <crc>, <chunkType>, <lastSrc>, <functionMayHaveChanged>)
	}
	return (first entry)
}

method assignFunctionIDs SmallRuntime {
	// Ensure that there is a chunk ID for every user-defined function.
	// This must be done before generating any code to allow for recursive calls.

	for func (allFunctions (project scripter)) {
		fName = (functionName func)
		if (not (contains chunkIDs fName)) {
			id = (unusedChunkID this)
			entry = (array id nil (chunkTypeFor this func) '' true)
			atPut chunkIDs fName entry // fName -> (<id>, <crc>, <chunkType>, <lastSrc>, <functionMayHaveChanged>)
		}
	}
}

method functionNameForID SmallRuntime chunkID {
	assignFunctionIDs this
	for pair (sortedPairs chunkIDs) {
		id = (first (first pair))
		if (id == chunkID) { return (last pair) } // return function name
	}
	return (join 'f' chunkID)
}

method deleteChunkForBlock SmallRuntime aBlock {
	key = aBlock
	if (isPrototypeHat aBlock) {
		key = (functionName (function (editedPrototype aBlock)))
	}
	entry = (at chunkIDs key nil)
	if (and (notNil entry) (notNil port)) {
		chunkID = (first entry)
		sendMsgSync this 'deleteChunkMsg' chunkID
		remove chunkIDs key
	}
}

method stopAndSyncScripts SmallRuntime alreadyStopped {
	// Stop everything. Sync and verify scripts with the board using chunk CRC's.
	setCursor 'wait'

	removeHint (global 'page')
	if (and (notNil port) (true != alreadyStopped)) {
		sendStopAll this
		softReset this
	}
	clearRunningHighlights this
	doOneCycle (global 'page')
	saveAllChunks this
	verifyCRCs this

	setCursor 'default'
}

method stopAndClearChunks SmallRuntime {
	// Stop any running scripts and clear chunks dictionary. Used when a screen resolution
	// change forces all scripts to be rebuilt.

	sendMsg this 'stopAllMsg'
	chunkIDs = (dictionary)
	chunkRunning = (newArray 256 false) // clear all running flags
}

method softReset SmallRuntime {
	// Stop everyting, clear memory, and reset the I/O pins.

	sendMsg this 'systemResetMsg' // send the reset message
}

method isWebSerial SmallRuntime {
	return (and ('Browser' == (platform)) (browserHasWebSerial))
}

method webSerialConnect SmallRuntime action {
	if ('disconnect' == action) {
		stopAndSyncScripts this
		sendStartAll this
		closeSerialPort 1
		portName = nil
		port = nil
	} else {
		stopAndClearChunks this
		openSerialPort 'webserial' 115200
		disconnected = false
		connectionStartTime = (msecsSinceStart)
		portName = 'webserial'
		port = 1
	}
}

method selectPort SmallRuntime {
	if (isNil disconnected) { disconnected = false }

	if (isWebSerial this) {
		if (not (isOpenSerialPort 1)) {
			webSerialConnect this 'connect'
		} else {
			menu = (menu 'Connect' (action 'webSerialConnect' this) true)
			addItem menu 'disconnect'
			popUpAtHand menu (global 'page')
		}
		return
	} (and ('Browser' == (platform)) (not (browserIsChromeOS))) { // running in a browser w/o WebSerial (or it is not enabled)
		inform (localized 'Only recent Chrome and Edge browsers support WebSerial.')
		return
	}

	portList = (portList this)
	menu = (menu 'Connect' (action 'setPort' this) true)
	if (or disconnected (devMode)) {
		for s portList {
			if (or (isNil port) (portName != s)) { addItem menu s }
		}
		if (isEmpty portList) {
			addItem menu 'Connect board and try again'
		}
	}
	if (and (devMode) ('Browser' != (platform))) {
		addItem menu 'other...'
	}
	if (notNil port) {
		addLine menu
		if (notNil portName) {
			addItem menu (join 'disconnect (' portName ')')
		} else {
			addItem menu 'disconnect'
		}
	}
	popUpAtHand menu (global 'page')
}

method portList SmallRuntime {
	portList = (list)
	if ('Win' == (platform)) {
		portList = (list)
		for pname (listSerialPorts) {
			blackListed = (or
				((containsSubString pname 'Bluetooth') > 0)
				((containsSubString pname '(COM1)') > 0)
				((containsSubString pname 'Intel(R) Active Management') > 0))
			if (not blackListed) {
				add portList pname
			}
		}
	} ('Browser' == (platform)) {
		listSerialPorts // first call triggers callback
		waitMSecs 5
		portList = (list)
		for portName (listSerialPorts) {
			if (not (beginsWith portName '/dev/tty.')) {
				add portList portName
			}
		}
	} else {
		for fn (listFiles '/dev') {
			if (or	(notNil (nextMatchIn 'usb' (toLowerCase fn) )) // MacOS
					(notNil (nextMatchIn 'acm' (toLowerCase fn) ))) { // Linux
				add portList (join '/dev/' fn)
			}
		}
		if ('Linux' == (platform)) {
			// add pseudoterminal
			ptyName = (readFile '/tmp/ublocksptyname')
			if (notNil ptyName) {
				add portList ptyName
			}
		}
		// Mac OS lists a port as both cu.<name> and tty.<name>
		for s (copy portList) {
			if (beginsWith s '/dev/tty.') {
				if (contains portList (join '/dev/cu.' (substring s 10))) {
					remove portList s
				}
			}
		}
	}
	return portList
}

method setPort SmallRuntime newPortName {
	if (beginsWith newPortName 'Connect board and try again') { return }
	if (beginsWith newPortName 'disconnect') {
		if (notNil port) {
			stopAndSyncScripts this
			sendStartAll this
		}
		disconnected = true
		closePort this
		updateIndicator (findMicroBlocksEditor)
		return
	}
	if ('other...' == newPortName) {
		newPortName = (prompt (global 'page') 'Port name?' (localized 'none'))
		if ('' == newPortName) { return }
	}
	closePort this
	disconnected = false

	// the prompt answer 'none' is entered by the user in the current language
	if (or (isNil newPortName) (newPortName == (localized 'none'))) {
		portName = nil
	} else {
		portName = newPortName
		openPortAndSendPing this
	}
	updateIndicator (findMicroBlocksEditor)
}

method closePort SmallRuntime {
	// Close the serial port and clear info about the currently connected board.

	if (notNil port) { closeSerialPort port }
	port = nil
	vmVersion = nil
	boardType = nil

	// remove running highlights and result bubbles when disconnected
	clearRunningHighlights this
}

method enableAutoConnect SmallRuntime success {
	closeAllDialogs (findMicroBlocksEditor)
	if ('Browser' == (platform)) {
		// In the browser, the serial port must be closed and re-opened after installing
		// firmware on an ESP board. Not sure why. Adding a delay did not help.
		closePort this
		closeSerialPort 1 // make sure port is really disconnected
		disconnected = true
		if success { otherReconnectMessage this }
		return
	}
	disconnected = false
	stopAndSyncScripts this
}

method tryToInstallVM SmallRuntime {
	// Invite the user to install VM if we see a new board drive and are not able to connect to
	// it within a few seconds. Remember the last set of boardDrives so we don't keep asking.
	// Details: On Mac OS (at least), 3-4 seconds elapse between when the board drive appears
	// and when the USB-serial port appears. Thus, the IDE waits a bit to see if it can connect
	// to the board before prompting the user to install the VM to avoid spurious prompts.

	if (and (notNil vmInstallMSecs) ((msecsSinceStart) > vmInstallMSecs)) {
		vmInstallMSecs = nil
		if (and (notNil port) (isOpenSerialPort port)) { return }
		ok = (confirm (global 'page') nil (join
			(localized 'The board is not responding.') (newline)
			(localized 'Try to Install MicroBlocks on the board?')))
		if ok { installVM this }
		return
	}

	boardDrives = (collectBoardDrives this)
	if (lastBoardDrives == boardDrives) { return }
	lastBoardDrives = boardDrives
	if (isEmpty boardDrives) {
		vmInstallMSecs = nil
	} else {
		vmInstallMSecs = ((msecsSinceStart) + 5000) // prompt to install VM in a few seconds
	}
}

method updateConnection SmallRuntime {
	pingSendInterval = 2000 // msecs between pings
	pingTimeout = 8000
	if (isNil pingSentMSecs) { pingSentMSecs = 0 }
	if (isNil lastPingRecvMSecs) { lastPingRecvMSecs = 0 }
	if (isNil disconnected) { disconnected = false }

	if (notNil decompiler) { return 'connected' }
	if disconnected { return 'not connected' }

	// handle connection attempt in progress
	if (notNil connectionStartTime) { return (tryToConnect this) }

	// if port is not open, try to reconnect or find a different board
	if (or (isNil port) (not (isOpenSerialPort port))) {
		clearRunningHighlights this
		closePort this
		if (isWebSerial this) { return 'not connected' } // user must initiate connection attempt
		return (tryToConnect this)
	}

	// if the port is open and it is time, send a ping
	now = (msecsSinceStart)
	if ((now - pingSentMSecs) > pingSendInterval) {
		if ((now - pingSentMSecs) > 5000) {
			// it's been a long time since we sent a ping; laptop may have been asleep
			// set lastPingRecvMSecs to N seconds into future to suppress warnings
			lastPingRecvMSecs = now
		}
		sendMsg this 'pingMsg'
		pingSentMSecs = now
		return 'connected'
	}

	msecsSinceLastPing = (now - lastPingRecvMSecs)
	if (msecsSinceLastPing < pingTimeout) {
		// got a ping recently: we're connected
		return 'connected'
	} else {
		// ping timeout: close port to force reconnection
		print 'Lost communication to the board'
		clearRunningHighlights this
		if (not (isWebSerial this)) { closePort this }
		return 'not connected'
	}
}

method tryToConnect SmallRuntime {
	// Called when connectionStartTime is not nil, indicating that we are trying
	// to establish a connection to a board the current serial port.
	if (and
		(not (hasUserCode (project (findProjectEditor))))
		(autoDecompileEnabled (findMicroBlocksEditor))
	) {
		readFromBoard = true
	}

	if (isWebSerial this) {
		if (isOpenSerialPort 1) {
			portName = 'webserial'
			port = 1
			waitForPing this // wait up to 1 second for ping
			pingSentMSecs = (msecsSinceStart)
			print 'Connected to' portName
			connectionStartTime = nil
			vmVersion = nil
			sendMsgSync this 'getVersionMsg'
			clearRunningHighlights this
			setDefaultSerialDelay this
			if readFromBoard {
				readFromBoard = false
				sendStopAll this
				readCodeFromBoard this
			} else {
				clearBoardIfConnected this false
				stopAndSyncScripts this true
			}
			return 'not connected' // don't make circle green until successful ping
		} else {
			portName = nil
			port = nil
			return 'not connected'
		}
	}

	connectionAttemptTimeout = 5000 // milliseconds

	// check connection status only N times/sec
	now = (msecsSinceStart)
	if (isNil lastScanMSecs) { lastScanMSecs = 0 }
	msecsSinceLastScan = (now - lastScanMSecs)
	if (and (msecsSinceLastScan > 0) (msecsSinceLastScan < 20)) { return 'not connected' }
	lastScanMSecs = now

	if (notNil connectionStartTime) {
		sendMsg this 'pingMsg'
		processMessages this
		if (lastPingRecvMSecs != 0) { // got a ping; we're connected!
			print 'Connected to' portName
			connectionStartTime = nil
			vmVersion = nil
			sendMsgSync this 'getVersionMsg'
			clearRunningHighlights this
			setDefaultSerialDelay this
			if readFromBoard {
				readFromBoard = false
				sendStopAll this
				readCodeFromBoard this
			} else {
				clearBoardIfConnected this false
				stopAndSyncScripts this true
			}
			return 'connected'
		}
		if (now < connectionStartTime) { connectionStartTime = now } // clock wrap
		if ((now - connectionStartTime) < connectionAttemptTimeout) { return 'not connected' } // keep trying
	}

	closePort this
	connectionStartTime = nil

	if ('Browser' == (platform)) {  // disable autoconnect on ChromeOS
		disconnected = true
		return 'not connected'
	}

	portNames = (portList this)
	if (isEmpty portNames) { return 'not connected' } // no ports available

	// try the port following portName in portNames
	// xxx to do: after trying all the ports, call tryToInstallVM (but only if portNames isn't empty)
	i = 1
	if (notNil portName) {
		i = (indexOf portNames portName)
		if (isNil i) { i = 0 }
		i = ((i % (count portNames)) + 1)
	}
	portName = (at portNames i)
	openPortAndSendPing this
}

method openPortAndSendPing SmallRuntime {
	// Open port and send ping request
	closePort this // ensure port is closed
	connectionStartTime = (msecsSinceStart)
	ensurePortOpen this // attempt to reopen the port
	lastPingRecvMSecs = 0
	sendMsg this 'pingMsg'
}

method ideVersion SmallRuntime { return ideVersion }
method latestVmVersion SmallRuntime { return latestVmVersion }

method ideVersionNumber SmallRuntime {
	// Return the version number portion of the version string (i.e. just digits and periods).

	for i (count ideVersion) {
		ch = (at ideVersion i)
		if (not (or (isDigit ch) ('.' == ch))) {
			return (substring ideVersion 1 (i - 1))
		}
	}
	return ideVersion
}

method readVersionFile SmallRuntime {
	// defaults in case version file is missing (which shouldn't happen)
	ideVersion = '0.0.0'
	latestVmVersion = 0

	data = (readEmbeddedFile 'versions')
	if (isNil data) { data = (readFile 'runtime/versions') }
	if (notNil data) {
		for s (lines data) {
			if (beginsWith s 'IDE ') { ideVersion = (substring s 5) }
			if (beginsWith s 'VM ') { latestVmVersion = (toNumber (substring s 4)) }
		}
	}
}

method showAboutBox SmallRuntime {
	vmVersionReport = (newline)
	if (notNil vmVersion) {
		vmVersionReport = (join ' (Firmware v' vmVersion ')' (newline))
	}
	(inform (global 'page') (join
		'MicroBlocks v' (ideVersion this) vmVersionReport (newline)
		(localized 'by') ' John Maloney, Bernat Romagosa, & Jens Mönig.' (newline)
		(localized 'Created with GP') ' (gpblocks.org)' (newline) (newline)
		(localized 'More info at http://microblocks.fun')) 'About MicroBlocks')
}

method checkBoardType SmallRuntime {
	if (and (isNil boardType) (notNil port)) {
		vmVersion = nil
		getVersion this
	}
	return boardType
}

method getVersion SmallRuntime {
	sendMsg this 'getVersionMsg'
}

method extractVersionNumber SmallRuntime versionString {
	// Return the version number from the versionString.
	// Version string format: vNNN, where NNN is one or more decimal digits,
	// followed by non-digits characters that are ignored. Ex: 'v052a micro:bit'

	words = (words (substring versionString 2))
	if (isEmpty words) { return -1 }
	result = 0
	for ch (letters (first words)) {
		if (not (isDigit ch)) { return result }
		digit = ((byteAt ch 1) - (byteAt '0' 1))
		result = ((10 * result) + digit)
	}
	return result
}

method extractBoardType SmallRuntime versionString {
	// Return the board type from the versionString.
	// Version string format: vNNN [boardType]

	words = (words (substring versionString 2))
	if (isEmpty words) { return -1 }
	return (joinStrings (copyWithout words (at words 1)) ' ')
}

method versionReceived SmallRuntime versionString {
	if (isNil vmVersion) { // first time: record and check the version number
		vmVersion = (extractVersionNumber this versionString)
		boardType = (extractBoardType this versionString)
		checkVmVersion this
		installBoardSpecificBlocks this
	} else { // not first time: show the version number
		inform (global 'page') (join 'MicroBlocks Virtual Machine ' versionString) 'Firmware version'
	}
}

method checkVmVersion SmallRuntime {
	// prevent version check from running while the decompiler is working
	if (not readFromBoard) { return }
	if ((latestVmVersion this) > vmVersion) {
		ok = (confirm (global 'page') nil (join
			(localized 'The MicroBlocks in your board is not current')
			' (v' vmVersion ' vs. v' (latestVmVersion this) ').' (newline)
			(localized 'Try to update MicroBlocks on the board?')))
		if ok { installVM this }
	}
}

method installBoardSpecificBlocks SmallRuntime {
	// installs default blocks libraries for each type of board.

	if readFromBoard { return } // don't load libraries while decompiling
	if (hasUserCode (project scripter)) { return } // don't load libraries if project has user code
	if (boardLibAutoLoadDisabled (findMicroBlocksEditor)) { return } // board lib autoload has been disabled by user

	if ('Citilab ED1' == boardType) {
		importEmbeddedLibrary scripter 'ED1 Buttons'
		importEmbeddedLibrary scripter 'Tone'
		importEmbeddedLibrary scripter 'Basic Sensors'
		importEmbeddedLibrary scripter 'LED Display'
	} (or ('micro:bit' == boardType) ('micro:bit v2' == boardType)) {
		importEmbeddedLibrary scripter 'Basic Sensors'
		importEmbeddedLibrary scripter 'LED Display'
		importEmbeddedLibrary scripter 'Scrolling'
	} ('Calliope' == boardType) {
		importEmbeddedLibrary scripter 'Calliope'
		importEmbeddedLibrary scripter 'Basic Sensors'
		importEmbeddedLibrary scripter 'LED Display'
		importEmbeddedLibrary scripter 'Scrolling'
	} ('CircuitPlayground' == boardType) {
		importEmbeddedLibrary scripter 'Circuit Playground'
		importEmbeddedLibrary scripter 'Basic Sensors'
		importEmbeddedLibrary scripter 'NeoPixel'
		importEmbeddedLibrary scripter 'Tone'
	} ('M5Stack-Core' == boardType) {
		importEmbeddedLibrary scripter 'Tone'
		importEmbeddedLibrary scripter 'LED Display'
		importEmbeddedLibrary scripter 'TFT'
		importEmbeddedLibrary scripter 'HTTP client'
	} ('ESP8266' == boardType) {
		importEmbeddedLibrary scripter 'HTTP client'
	} ('IOT-BUS' == boardType) {
		importEmbeddedLibrary scripter 'LED Display'
		importEmbeddedLibrary scripter 'TFT'
		importEmbeddedLibrary scripter 'touchScreenPrims'
	} ('ESP32' == boardType) {
		importEmbeddedLibrary scripter 'HTTP client'
	} ('TTGO RP2040' == boardType) {
		importEmbeddedLibrary scripter 'LED Display'
	}
}

method clearBoardIfConnected SmallRuntime doReset {
	if (notNil port) {
		sendStopAll this
		if doReset { softReset this }
		sendMsgSync this 'deleteAllCodeMsg' // delete all code from board
	}
	clearVariableNames this
	clearRunningHighlights this
	chunkIDs = (dictionary)
}

method sendStopAll SmallRuntime {
	sendMsg this 'stopAllMsg'
	clearRunningHighlights this
}

method sendStartAll SmallRuntime {
	step scripter // save script changes if needed
	sendMsg this 'startAllMsg'
}

// Saving and verifying

method suspendCodeFileUpdates SmallRuntime { sendMsg this 'extendedMsg' 2 (list) }
method resumeCodeFileUpdates SmallRuntime { sendMsg this 'extendedMsg' 3 (list) }

method reachableFunctions SmallRuntime {
	// Not currently used. This function finds all the functions in a project that
	// are called explicitly. This might be used to prune unused library functions
	// when downloading a project. However, it does not find dynamic calls that us
	// the "call" primitive, so it is a bit risky.

	proj = (project scripter)
	todo = (list)
	result = (dictionary)

	for aBlock (sortedScripts (scriptEditor scripter)) {
		if (isPrototypeHat aBlock) {
			// todo: add function name to todo list
		} else {
			add todo aBlock
		}
	}
	while (notEmpty todo) {
		blockOrFuncName = (removeFirst todo)
		expr = nil
		if (isClass blockOrFuncName 'Block') {
			expr = (expression blockOrFuncName)
		} (isClass blockOrFuncName 'String') {
			func = (functionNamed proj blockOrFuncName)
			if (notNil func) { expr = (cmdList func) }
		}
		if (notNil expr) {
			for b (allBlocks expr) {
				op = (primName b)
				if (and (not (contains result op)) (notNil (functionNamed proj op))) {
					add result op
					add todo op
				}
			}
		}
	}
	print (count result) 'reachable functions:'
	for fName (keys result) { print '  ' fName }
}

method saveAllChunks SmallRuntime {
	// Save the code for all scripts and user-defined functions.

	if (isNil port) { return }

t = (newTimer) // xxx

	suspendCodeFileUpdates this

	saveVariableNames this
	assignFunctionIDs this
	removeObsoleteChunks this

msecSplit t
	functionsSaved = 0
	for aFunction (allFunctions (project scripter)) {
		if (saveChunk this aFunction) { functionsSaved += 1 }
		if (isNil port) { return } // connection closed
	}
if (functionsSaved > 0) { print '  saved' functionsSaved 'functions' (join '(' (msecSplit t) ' msecs)') }

	scriptsSaved = 0
	for aBlock (sortedScripts (scriptEditor scripter)) {
		if (not (isPrototypeHat aBlock)) { // skip function def hat; functions get saved above
		if (saveChunk this aBlock) { scriptsSaved += 1 }
			if (isNil port) { return } // connection closed
		}
	}
if (scriptsSaved > 0) { print '  saved' scriptsSaved 'scripts' (join '(' (msecSplit t) ' msecs)') }

	resumeCodeFileUpdates this

print '** saveAllChunks' (join '(' (msecs t t) ' msecs)')
}

method forceSaveChunk SmallRuntime aBlockOrFunction {
	// Save the chunk for the given block or function even if it was previously saved.

	if (contains chunkIDs aBlockOrFunction) {
		atPut (at chunkIDs aBlockOrFunction) 4 '' // clear the old source to force re-save
	}
	saveChunk this aBlockOrFunction
}

method saveChunk SmallRuntime aBlockOrFunction {
	// Save the given script or function as an executable code "chunk".
	// Also save the source code (in GP format) and the script position.

	pp = (new 'PrettyPrinter')
	if (isClass aBlockOrFunction 'String') {
		aBlockOrFunction = (functionNamed (project scripter) aBlockOrFunction)
		if (isNil aBlockOrFunction) { return false } // unknown function
	}
	if (isClass aBlockOrFunction 'Function') {
		functionName = (functionName aBlockOrFunction)
		chunkID = (lookupChunkID this functionName)
		entry = (at chunkIDs functionName)
		if (not (at entry 5)) { return false } // function is not in scripting area so has not changed
		atPut entry 5 false
		currentSrc = (prettyPrintFunction pp aBlockOrFunction)
	} else {
		expr = (expression aBlockOrFunction)
		if (isClass expr 'Reporter') {
			currentSrc = (prettyPrint pp expr)
		} else {
			currentSrc = (prettyPrintList pp expr)
		}
		chunkID = (ensureChunkIdFor this aBlockOrFunction)
		entry = (at chunkIDs aBlockOrFunction)
		if ((at entry 3) != (chunkTypeFor this aBlockOrFunction)) {
			// user changed A/B/A+B button hat type with menu
			atPut entry 3 (chunkTypeFor this aBlockOrFunction)
			atPut entry 4 '' // clear lastSrc to force save
		}
	}

	if (currentSrc == (at entry 4)) { return false } // source hasn't changed; save not needed
	atPut entry 4 currentSrc // remember the source of the code we're about to save

	// save the binary code for the chunk
	chunkType = (chunkTypeFor this aBlockOrFunction)
	chunkBytes = (chunkBytesFor this aBlockOrFunction)
	data = (list chunkType)
	addAll data chunkBytes
	if ((count data) > 1000) {
		if (isClass aBlockOrFunction 'Function') {
			inform (global 'page') (join
				(localized 'Function "') (functionName aBlockOrFunction)
				(localized '" is too large to send to board.'))
		} else {
			showError (morph aBlockOrFunction) (localized 'Script is too large to send to board.')
		}
		return false
	}
	sendMsgSync this 'chunkCodeMsg' chunkID data
	atPut entry 2 (computeCRC this chunkBytes) // remember the CRC of the code we just saved

	// restart the chunk if it is a Block and is running
	if (and (isClass aBlockOrFunction 'Block') (isRunning this aBlockOrFunction)) {
		stopRunningChunk this chunkID
		waitForResponse this
		runChunk this chunkID
		waitForResponse this
	}
	return true
}

method computeCRC SmallRuntime chunkData {
	// Return the CRC for the given compiled code.

	crc = (crc (toBinaryData (toArray chunkData)))

	// convert crc to a 4-byte array
	result = (newArray 4)
	for i 4 { atPut result i (digitAt crc i) }
	return result
}


method verifyCRCs SmallRuntime {
	// Check that the CRCs of the chunks on the board match the ones in the IDE.
	// Resend the code of any chunks whose CRC's do not match.

	if (isNil port) { return }

t = (newTimer) // xxx
	// collect CRCs from the board
	crcDict = (dictionary)
collectType = ''
	if (and (notNil vmVersion) (vmVersion >= 159)) {
collectType = 'bulk'
		collectCRCsBulk this
	} else {
collectType = 'individually'
		collectCRCsIndividually this
	}
collectCRCsMsecs = (msecSplit t)

	// build dictionaries:
	//  ideChunks: maps chunkID -> block or functionName
	//  crcForChunkID: maps chunkID -> CRC
	ideChunks = (dictionary)
	crcForChunkID = (dictionary)
	for pair (sortedPairs chunkIDs) {
		id = (first (first pair))
		key = (last pair)
		if (and (isClass key 'String') (isNil (functionNamed (project scripter) key))) {
			remove chunkIDs key // remove reference to deleted function (rarely needed)
		} else {
			atPut ideChunks id (last pair)
			atPut crcForChunkID id (at (first pair) 2)
		}
	}

	// process CRCs
	for chunkID (keys crcDict) {
		sourceItem = (at ideChunks chunkID)
		if (and (notNil sourceItem) ((at crcDict chunkID) != (at crcForChunkID chunkID))) {
			print 'CRC mismatch; resaving chunk:' chunkID
			forceSaveChunk this sourceItem
		}
	}

	// check for missing chunks
	for chunkID (keys ideChunks) {
		if (not (contains crcDict chunkID)) {
			print 'Resaving missing chunk:' chunkID
			sourceItem = (at ideChunks chunkID)
			forceSaveChunk this sourceItem
		}
	}

totalMSecs = (msecs t)
print '** verifyCRCs' (join '(' collectType ')') 'msecs:' (msecs t) '( collectCRCs:' collectCRCsMsecs 'other:' (totalMSecs - collectCRCsMsecs) ')'
}

method collectCRCsIndividually SmallRuntime {
	// Collect the CRC's from all chunks on the board by requesting them individually

	crcDict = (dictionary)

	// request a CRC for every chunk
	for entry (values chunkIDs) {
		sendMsg this 'getChunkCRCMsg' (first entry)
		processMessages this
	}

	waitForResponse this // wait for the first response

	timeout = 30
	lastRcvMSecs = (msecsSinceStart)
	while (((msecsSinceStart) - lastRcvMSecs) < timeout) {
		processMessages this
		waitMSecs 10
	}
}

method crcReceived SmallRuntime chunkID chunkCRC {
	// Received an individual CRC message from board.
	// Record the CRC for the given chunkID.

	lastRcvMSecs = (msecsSinceStart)
	if (notNil crcDict) {
		atPut crcDict chunkID chunkCRC
	}
}

method collectCRCsBulk SmallRuntime {
	// Collect the CRC's from all chunks on the board via a bulk CRC request.

	crcDict = nil

	// request CRCs for all chunks on board
	sendMsg this 'getAllCRCsMsg'

	// wait until crcDict is filled in or timeout
	startT = (msecsSinceStart)
	while (and (isNil crcDict) (((msecsSinceStart) - startT) < 2000)) {
		processMessages this
		waitMSecs 5
	}
	if (isNil crcDict) { crcDict = (dictionary) } // timeout
}

method allCRCsReceived SmallRuntime data {
	// Received a message from baord with the CRCs of all chunks.
	// Create crcDict and record the (possibly empty) list of CRCs.
	// Each CRC record is 5 bytes: <chunkID (one byte)> <CRC (four bytes)>

	crcDict = (dictionary)
	byteCount = (count data)
	i = 1
	while (i <= (byteCount - 4)) {
		chunkID = (at data i)
		chunkCRC = (copyFromTo data (i + 1) (i + 4))
		atPut crcDict chunkID chunkCRC
		i += 5
	}
}

method saveVariableNames SmallRuntime {
	newVarNames = (allVariableNames (project scripter))
	if (oldVarNames == newVarNames) { return }

	clearVariableNames this
	varID = 0
	for varName newVarNames {
		if (notNil port) {
			sendMsgSync this 'varNameMsg' varID (toArray (toBinaryData varName))
		}
		varID += 1
	}
	oldVarNames = (copy newVarNames)
}

method runChunk SmallRuntime chunkID {
	sendMsg this 'startChunkMsg' chunkID
}

method stopRunningChunk SmallRuntime chunkID {
	sendMsg this 'stopChunkMsg' chunkID
}

method sendBroadcastToBoard SmallRuntime msg {
	sendMsg this 'broadcastMsg' 0 (toArray (toBinaryData msg))
}

method getVar SmallRuntime varID {
	if (isNil varID) { varID = 0 }
	sendMsg this 'getVarMsg' varID
}

method getVarNamed SmallRuntime varName {
	sendMsg this 'getVarMsg' 255 (toArray (toBinaryData varName))
}

method setVar SmallRuntime varID val {
	body = nil
	if (isClass val 'Integer') {
		body = (newArray 5)
		atPut body 1 1 // type 1 - Integer
		atPut body 2 (val & 255)
		atPut body 3 ((val >> 8) & 255)
		atPut body 4 ((val >> 16) & 255)
		atPut body 5 ((val >> 24) & 255)
	} (isClass val 'String') {
		body = (toArray (toBinaryData (join (string 2) val)))
	} (isClass val 'Boolean') {
		body = (newArray 2)
		atPut body 1 3 // type 3 - Boolean
		if val {
			atPut body 2 1 // true
		} else {
			atPut body 2 0 // false
		}
	}
	if (notNil body) { sendMsg this 'setVarMsg' varID body }
}

method variablesChanged SmallRuntime {
	// Called by scripter when variables are added or removed.

	sendStopAll this
	clearVariableNames this
	scriptChanged scripter
}

method clearVariableNames SmallRuntime {
	if (notNil port) { sendMsgSync this 'clearVarsMsg' }
	oldVarNames = nil
}

// Serial Delay

method serialDelayMenu SmallRuntime {
	menu = (menu (join 'Serial delay' (newline) '(smaller is faster, but may fail if computer cannot keep up)') (action 'setSerialDelay' this) true)
	for i (range 1 5) { addItem menu i }
	for i (range 6 20 2) { addItem menu i }
	addLine menu
	addItem menu 'reset to default'
	popUpAtHand menu (global 'page')
}

method setDefaultSerialDelay SmallRuntime {
	setSerialDelay this 'reset to default'
}

method setSerialDelay SmallRuntime newDelay {
	if ('reset to default' == newDelay) {
		newDelay = 5
	}
	sendMsg this 'extendedMsg' 1 (list newDelay)
}

// Message handling

method msgNameToID SmallRuntime msgName {
	if (isClass msgName 'Integer') { return msgName }
	if (isNil msgDict) {
		msgDict = (dictionary)
		atPut msgDict 'chunkCodeMsg' 1
		atPut msgDict 'deleteChunkMsg' 2
		atPut msgDict 'startChunkMsg' 3
		atPut msgDict 'stopChunkMsg' 4
		atPut msgDict 'startAllMsg' 5
		atPut msgDict 'stopAllMsg' 6
		atPut msgDict 'getVarMsg' 7
		atPut msgDict 'setVarMsg' 8
		atPut msgDict 'getVarNamesMsg' 9
		atPut msgDict 'clearVarsMsg' 10
		atPut msgDict 'getChunkCRCMsg' 11
		atPut msgDict 'getVersionMsg' 12
		atPut msgDict 'getAllCodeMsg' 13
		atPut msgDict 'deleteAllCodeMsg' 14
		atPut msgDict 'systemResetMsg' 15
		atPut msgDict 'taskStartedMsg' 16
		atPut msgDict 'taskDoneMsg' 17
		atPut msgDict 'taskReturnedValueMsg' 18
		atPut msgDict 'taskErrorMsg' 19
		atPut msgDict 'outputValueMsg' 20
		atPut msgDict 'varValueMsg' 21
		atPut msgDict 'versionMsg' 22
		atPut msgDict 'chunkCRCMsg' 23
		atPut msgDict 'pingMsg' 26
		atPut msgDict 'broadcastMsg' 27
		atPut msgDict 'chunkAttributeMsg' 28
		atPut msgDict 'varNameMsg' 29
		atPut msgDict 'extendedMsg' 30
		atPut msgDict 'getAllCRCsMsg' 38
		atPut msgDict 'allCRCsMsg' 39
		atPut msgDict 'deleteFile' 200
		atPut msgDict 'listFiles' 201
		atPut msgDict 'fileInfo' 202
		atPut msgDict 'startReadingFile' 203
		atPut msgDict 'startWritingFile' 204
		atPut msgDict 'fileChunk' 205
	}
	msgType = (at msgDict msgName)
	if (isNil msgType) { error 'Unknown message:' msgName }
	return msgType
}

method errorString SmallRuntime errID {
	// Return an error string for the given errID from error definitions copied and pasted from interp.h

	defsFromHeaderFile = '
#define noError					0	// No error
#define unspecifiedError		1	// Unknown error
#define badChunkIndexError		2	// Unknown chunk index

#define insufficientMemoryError	10	// Insufficient memory to allocate object
#define needsListError			11	// Needs a list
#define needsBooleanError		12	// Needs a boolean
#define needsIntegerError		13	// Needs an integer
#define needsStringError		14	// Needs a string
#define nonComparableError		15	// Those objects cannot be compared for equality
#define arraySizeError			16	// List size must be a non-negative integer
#define needsIntegerIndexError	17	// List or string index must be an integer
#define indexOutOfRangeError	18	// List or string index out of range
#define byteArrayStoreError		19	// A ByteArray can only store integer values between 0 and 255
#define hexRangeError			20	// Hexadecimal input must between between -1FFFFFFF and 1FFFFFFF
#define i2cDeviceIDOutOfRange	21	// I2C device ID must be between 0 and 127
#define i2cRegisterIDOutOfRange	22	// I2C register must be between 0 and 255
#define i2cValueOutOfRange		23	// I2C value must be between 0 and 255
#define notInFunction			24	// Attempt to access an argument outside of a function
#define badForLoopArg			25	// for-loop argument must be a positive integer or list
#define stackOverflow			26	// Insufficient stack space
#define primitiveNotImplemented	27	// Primitive not implemented in this virtual machine
#define notEnoughArguments		28	// Not enough arguments passed to primitive
#define waitTooLong				29	// The maximum wait time is 3600000 milliseconds (one hour)
#define noWiFi					30	// This board does not support WiFi
#define zeroDivide				31	// Division (or modulo) by zero is not defined
#define argIndexOutOfRange		32	// Argument index out of range
#define needsIndexable			33	// Needs an indexable type such as a string or list
#define joinArgsNotSameType		34	// All arguments to join must be the same type (e.g. lists)
#define i2cTransferFailed		35	// I2C transfer failed
#define needsByteArray			36	// Needs a byte array
#define serialPortNotOpen		37	// Serial port not open
#define serialWriteTooBig		38	// Serial port write is limited to 128 bytes
#define needsListOfIntegers		39	// Needs a list of integers
#define byteOutOfRange			40	// Needs a value between 0 and 255
'
	for line (lines defsFromHeaderFile) {
		words = (words line)
		if (and ((count words) > 2) ('#define' == (first words))) {
			if (errID == (toInteger (at words 3))) {
				msg = (joinStrings (copyFromTo words 5) ' ')
				return (join 'Error: ' msg)
			}
		}
	}
	return (join 'Unknown error: ' errID)
}

method sendMsg SmallRuntime msgName chunkID byteList {
	ensurePortOpen this
	if (isNil port) { return }

	if (isNil chunkID) { chunkID = 0 }
	msgID = (msgNameToID this msgName)
	if (isNil byteList) { // short message
		msg = (list 250 msgID chunkID)
	} else { // long message
		byteCount = ((count byteList) + 1)
		msg = (list 251 msgID chunkID (byteCount & 255) ((byteCount >> 8) & 255))
		addAll msg byteList
		add msg 254 // terminator byte (helps board detect dropped bytes)
	}
	dataToSend = (toBinaryData (toArray msg))
	while ((byteCount dataToSend) > 0) {
		// Note: Adafruit USB-serial drivers on Mac OS locks up if >= 1024 bytes
		// written in one call to writeSerialPort, so send smaller chunks
		byteCount = (min 50 (byteCount dataToSend))
		chunk = (copyFromTo dataToSend 1 byteCount)
		bytesSent = (writeSerialPort port chunk)
		if (not (isOpenSerialPort port)) {
			closePort this
			return
		}
		waitMSecs 2
		if (bytesSent < byteCount) { waitMSecs 200 } // output queue full; wait a bit
		dataToSend = (copyFromTo dataToSend (bytesSent + 1))
	}
}

method sendMsgSync SmallRuntime msgName chunkID byteList {
	// Send a message followed by a 'pingMsg', then a wait for a ping response from VM.

	readAvailableSerialData this
	sendMsg this msgName chunkID byteList
	ok = (waitForResponse this)
	if (not ok) {
		print 'Lost communication to the board in sendMsgSync'
		closePort this
		return false
	}
	return true
}

method readAvailableSerialData SmallRuntime {
	// Read any available data into recvBuf so that waitForResponse will await fresh data.

	if (isNil port) { return }
	waitMSecs 20 // leave some time for queued data to arrive
	if (isNil recvBuf) { recvBuf = (newBinaryData 0) }
	s = (readSerialPort port true)
	if (notNil s) { recvBuf = (join recvBuf s) }
}

method waitForResponse SmallRuntime {
	// Wait for some data to arrive from the board. This is taken to mean that the
	// previous operation has completed. Return true if a response was received.

	sendMsg this 'pingMsg'
	timeout = 10000 // enough time for a long Flash compaction
	start = (msecsSinceStart)
	while (((msecsSinceStart) - start) < timeout) {
		if (isNil port) { return false }
		s = (readSerialPort port true)
		if (notNil s) {
			recvBuf = (join recvBuf s)
			return true
		}
		sendMsg this 'pingMsg'
		waitMSecs 5
	}
	return false
}

method ensurePortOpen SmallRuntime {
	if (true == disconnected) { return }
	if (isWebSerial this) { return }
	if (or (isNil port) (not (isOpenSerialPort port))) {
		if (and (notNil portName)
				(or (contains (portList this) portName)
				(notNil (findSubstring 'pts' portName)))) { // support for GnuBlocks
			port = (safelyRun (action 'openSerialPort' portName 115200))
			if (not (isClass port 'Integer')) { port = nil } // failed
			if (isNil port) { return }
			// connected!
			disconnected = false
			if ('Browser' == (platform)) { waitMSecs 100 } // let browser callback complete
		}
	}
}

method processMessages SmallRuntime {
	if (isNil recvBuf) { recvBuf = (newBinaryData 0) }
	repeat 100 { // process up to N messages
		if (not (processNextMessage this)) { return } // done!
	}
}

method processNextMessage SmallRuntime {
	// Process the next message, if any. Return false when there are no more messages.

	if (or (isNil port) (not (isOpenSerialPort port))) { return false }

	// Read any available bytes and append to recvBuf
	s = (readSerialPort port true)
	if (notNil s) { recvBuf = (join recvBuf s) }
	if ((byteCount recvBuf) < 3) { return false } // not enough bytes for even a short message

	// Parse and dispatch messages
	firstByte = (byteAt recvBuf 1)
	byteTwo = (byteAt recvBuf 2)
	if (or (byteTwo < 1) (and (40 <= byteTwo) (byteTwo < 200)) (byteTwo > 205)) {
		print 'Serial error, opcode:' (byteAt recvBuf 2)
		skipMessage this // discard unrecognized message
		return true
	}
	if (250 == firstByte) { // short message
		msg = (copyFromTo recvBuf 1 3)
		recvBuf = (copyFromTo recvBuf 4) // remove message
		handleMessage this msg
	} (251 == firstByte) { // long message
		if ((byteCount recvBuf) < 5) { return false } // incomplete length field
		bodyBytes = (((byteAt recvBuf 5) << 8) | (byteAt recvBuf 4))
		if (bodyBytes >= 1024) {
			print 'Serial error, length:' bodyBytes
			skipMessage this // discard unrecognized message
			return true
		}
		if ((byteCount recvBuf) < (5 + bodyBytes)) { return false } // incomplete body
		msg = (copyFromTo recvBuf 1 (bodyBytes + 5))
		recvBuf = (copyFromTo recvBuf (bodyBytes + 6)) // remove message
		handleMessage this msg
	} else {
		print 'Serial error, start byte:' firstByte
		print (toString recvBuf) // show the string (could be an ESP error message)
		skipMessage this // discard
	}
	return true
}

method skipMessage SmallRuntime {
	// Discard bytes in recvBuf until the start of the next message, if any.

	end = (byteCount recvBuf)
	i = 2
	while (i < end) {
		byte = (byteAt recvBuf i)
		if (or (250 == byte) (251 == byte)) {
			recvBuf = (copyFromTo recvBuf i)
			return
		}
		i += 1
	}
	recvBuf = (newBinaryData 0) // no message start found; discard entire buffer
}

// Message handling

method handleMessage SmallRuntime msg {
	lastPingRecvMSecs = (msecsSinceStart) // reset ping timer when any valid message is recevied
	op = (byteAt msg 2)
	if (op == (msgNameToID this 'taskStartedMsg')) {
		updateRunning this (byteAt msg 3) true
	} (op == (msgNameToID this 'taskDoneMsg')) {
		updateRunning this (byteAt msg 3) false
	} (op == (msgNameToID this 'taskReturnedValueMsg')) {
		chunkID = (byteAt msg 3)
		showResult this chunkID (returnedValue this msg) false true
		updateRunning this chunkID false
	} (op == (msgNameToID this 'taskErrorMsg')) {
		chunkID = (byteAt msg 3)
		showError this chunkID (errorString this (byteAt msg 6))
		updateRunning this chunkID false
	} (op == (msgNameToID this 'outputValueMsg')) {
		chunkID = (byteAt msg 3)
		if (chunkID == 255) {
			print (returnedValue this msg)
		} (chunkID == 254) {
			addLoggedData this (toString (returnedValue this msg))
		} else {
			showResult this chunkID (returnedValue this msg) false true
		}
	} (op == (msgNameToID this 'varValueMsg')) {
		varValueReceived (httpServer scripter) (byteAt msg 3) (returnedValue this msg)
	} (op == (msgNameToID this 'versionMsg')) {
		versionReceived this (returnedValue this msg)
	} (op == (msgNameToID this 'chunkCRCMsg')) {
		crcReceived this (byteAt msg 3) (copyFromTo (toArray msg) 6)
	} (op == (msgNameToID this 'allCRCsMsg')) {
		allCRCsReceived this (copyFromTo (toArray msg) 6)
	} (op == (msgNameToID this 'pingMsg')) {
		lastPingRecvMSecs = (msecsSinceStart)
	} (op == (msgNameToID this 'broadcastMsg')) {
		broadcastReceived (httpServer scripter) (toString (copyFromTo msg 6))
	} (op == (msgNameToID this 'chunkCodeMsg')) {
		receivedChunk this (byteAt msg 3) (byteAt msg 6) (toArray (copyFromTo msg 7))
	} (op == (msgNameToID this 'chunkAttributeMsg')) {
		print 'chunkAttributeMsg:' (byteCount msg) 'bytes'
	} (op == (msgNameToID this 'varNameMsg')) {
		receivedVarName this (byteAt msg 3) (toString (copyFromTo msg 6)) ((byteCount msg) - 5)
	} (op == (msgNameToID this 'fileInfo')) {
		recordFileTransferMsg this (copyFromTo msg 6)
	} (op == (msgNameToID this 'fileChunk')) {
		recordFileTransferMsg this (copyFromTo msg 6)
	} else {
		print 'msg:' (toArray msg)
	}
}

method updateRunning SmallRuntime chunkID runFlag {
	if (isNil chunkRunning) {
		chunkRunning = (newArray 256 false)
	}
	atPut chunkRunning (chunkID + 1) runFlag
	updateHighlights this
}

method isRunning SmallRuntime aBlock {
	chunkID = (lookupChunkID this aBlock)
	if (or (isNil chunkRunning) (isNil chunkID)) { return false }
	return (at chunkRunning (chunkID + 1))
}

// File Transfer Support

method boardHasFileSystem SmallRuntime {
	if (true == disconnected) { return false }
	if (and (isWebSerial this) (not (isOpenSerialPort 1))) { return false }
	if (isNil port) { return false }
	if (isNil boardType) { getVersion this }
	return (isOneOf boardType 'Citilab ED1' 'M5Stack-Core' 'M5StickC+' 'M5StickC' 'M5Atom-Matrix' 'ESP32' 'ESP8266', 'RP2040', 'TTGO RP2040')
}

method deleteFileOnBoard SmallRuntime fileName {
	msg = (toArray (toBinaryData fileName))
	sendMsg this 'deleteFile' 0 msg
}

method getFileListFromBoard SmallRuntime {
	sendMsg this 'listFiles'
	collectFileTransferResponses this

	result = (list)
	for msg fileTransferMsgs {
		fileNum = (readInt32 this msg 1)
		fileSize = (readInt32 this msg 5)
		fileName = (toString (copyFromTo msg 9))
		add result fileName
	}
	return result
}

method getFileFromBoard SmallRuntime {
	setCursor 'wait'
	fileNames = (sorted (getFileListFromBoard this))
	setCursor 'default'
	if (isEmpty fileNames) {
		inform 'No files on board.'
		return
	}
	menu = (menu 'File to read from board:' (action 'getAndSaveFile' this) true)
	for fn fileNames {
		addItem menu fn
	}
	popUpAtHand menu (global 'page')
}

method getAndSaveFile SmallRuntime remoteFileName {
	data = (readFileFromBoard this remoteFileName)
	if ('Browser' == (platform)) {
		browserWriteFile data remoteFileName 'fileFromBoard'
	} else {
		fName = (fileToWrite remoteFileName)
		if ('' != fName) { writeFile fName data }
	}
}

method readFileFromBoard SmallRuntime remoteFileName {
	fileTransferProgress = 0
	spinner = (newSpinner (action 'fileTransferProgress' this 'downloaded') (action 'fileTransferCompleted' this))
	setStopAction spinner (action 'abortFileTransfer' this)
	addPart (global 'page') spinner

	msg = (list)
	id = (rand ((1 << 24) - 1))
	appendInt32 this msg id
	addAll msg (toArray (toBinaryData remoteFileName))
	sendMsg this 'startReadingFile' 0 msg
	collectFileTransferResponses this

	totalBytes = 0
	for msg fileTransferMsgs {
		// format: <transfer ID (4 byte int)><byte offset (4 byte int)><data...>
		transferID = (readInt32 this msg 1)
		offset = (readInt32 this msg 5)
		byteCount = ((byteCount msg) - 8)
		totalBytes += byteCount
		fileTransferProgress = (100 - (round (100 * (byteCount / totalBytes))))
		doOneCycle (global 'page')
	}

	result = (newBinaryData totalBytes)
	startIndex = 1
	for msg fileTransferMsgs {
		byteCount = ((byteCount msg) - 8)
		endIndex = ((startIndex + byteCount) - 1)
		if (byteCount > 0) { replaceByteRange result startIndex endIndex msg 9 }
		startIndex += byteCount
	}
	setCursor 'default'
	return result
}

method putFileOnBoard SmallRuntime {
	if ('Browser' == (platform)) {
		putNextDroppedFileOnBoard (findMicroBlocksEditor)
		browserReadFile ''
	} else {
		pickFileToOpen (action 'writeFileToBoard' this)
	}
}

method writeFileToBoard SmallRuntime srcFileName {
	if (notNil (findMorph 'MicroBlocksFilePicker')) {
		destroy (findMorph 'MicroBlocksFilePicker')
	}

	fileData = (readFile srcFileName true)
	if (isNil fileData) { return }

	targetFileName = (filePart srcFileName)
	if ((count targetFileName) > 30) {
		targetFileName = (substring targetFileName 1 30)
	}

	fileTransferProgress = 0
	spinner = (newSpinner (action 'fileTransferProgress' this 'uploaded') (action 'fileTransferCompleted' this))
	setStopAction spinner (action 'abortFileTransfer' this)
	addPart (global 'page') spinner

	sendFileData this targetFileName fileData
}

// busy tells the MicroBlocksEditor to suspect board communciations during file transfers
method busy SmallRuntime { return (notNil fileTransferProgress) }

method fileTransferProgress SmallRuntime actionLabel { return (join '' fileTransferProgress '% ' (localized actionLabel)) }
method abortFileTransfer SmallRuntime { fileTransferProgress = nil }

method fileTransferCompleted SmallRuntime {
	// return true if the file transfer is complete or aborted
	return (or (isNil fileTransferProgress) (fileTransferProgress == 100))
}

method sendFileData SmallRuntime fileName fileData {
	// send data as a sequence of chunks
	setCursor 'wait'
	fileTransferProgress = 0

	totalBytes = (byteCount fileData)
	id = (rand ((1 << 24) - 1))
	bytesSent = 0

	msg = (list)
	appendInt32 this msg id
	addAll msg (toArray (toBinaryData fileName))
	sendMsgSync this 'startWritingFile' 0 msg

	while (bytesSent < totalBytes) {
		if (isNil fileTransferProgress) {
			print 'File transfer aborted.'
			return
		}
		msg = (list)
		appendInt32 this msg id
		appendInt32 this msg bytesSent
		chunkByteCount = (min 960 (totalBytes - bytesSent))
		repeat chunkByteCount {
			bytesSent += 1
			add msg (byteAt fileData bytesSent)
		}
		sendMsgSync this 'fileChunk' 0 msg
		fileTransferProgress = (round (100 * (bytesSent / totalBytes)))
		doOneCycle (global 'page')
	}
	// final (empty) chunk
	msg = (list)
	appendInt32 this msg id
	appendInt32 this msg bytesSent
	sendMsgSync this 'fileChunk' 0 msg

	fileTransferProgress = nil
}

method appendInt32 SmallRuntime msg n {
	add msg (n & 255)
	add msg ((n >> 8) & 255)
	add msg ((n >> 16) & 255)
	add msg ((n >> 24) & 255)
}

method readInt32 SmallRuntime msg i {
	result = (byteAt msg i)
	result += ((byteAt msg (i + 1)) << 8)
	result += ((byteAt msg (i + 2)) << 16)
	result += ((byteAt msg (i + 3)) << 24)
	return result
}

method collectFileTransferResponses SmallRuntime {
	fileTransferMsgs = (list)
	timeout = 1000
	lastRcvMSecs = (msecsSinceStart)
	while (((msecsSinceStart) - lastRcvMSecs) < timeout) {
		if (notEmpty fileTransferMsgs) { timeout = 500 } // decrease timeout after first response
		processMessages this
		doOneCycle (global 'page')
		waitMSecs 10
	}
}

method recordFileTransferMsg SmallRuntime msg {
	// Record a file transfer message sent by board.

	if (notNil fileTransferMsgs) { add fileTransferMsgs msg }
	lastRcvMSecs = (msecsSinceStart)
}

// Script Highlighting

method clearRunningHighlights SmallRuntime {
	chunkRunning = (newArray 256 false) // clear all running flags
	updateHighlights this
}

method updateHighlights SmallRuntime {
	scale = (global 'scale')
	for m (parts (morph (scriptEditor scripter))) {
		if (isClass (handler m) 'Block') {
			if (isRunning this (handler m)) {
				addHighlight m
			} else {
				removeHighlight m
			}
		}
	}
}

method removeResultBubbles SmallRuntime {
	for m (allMorphs (morph (global 'page'))) {
		h = (handler m)
		if (and (isClass h 'SpeechBubble') (isClass (handler (clientMorph h)) 'Block')) {
			removeFromOwner m
		}
	}
}

method showError SmallRuntime chunkID msg {
	showResult this chunkID msg true
}

method showResult SmallRuntime chunkID value isError isResult {
	for m (join
			(parts (morph (scriptEditor scripter)))
			(parts (morph (blockPalette scripter)))) {
		h = (handler m)
		if (and (isClass h 'Block') (chunkID == (lookupChunkID this h))) {
			if (true == isError) {
				showError m value
			} else {
				showHint m value nil false
			}
			if (or (isNil value) ('' == value)) {
				removeHintForMorph (global 'page') m
			} else {
				if (shiftKeyDown (keyboard (global 'page'))) {
					setClipboard (toString value)
				}
			}
			if (and (true == isResult) (h == blockForResultImage)) {
				blockForResultImage = nil
				doOneCycle (global 'page')
				waitMSecs 500 // show result bubble briefly before showing menu
				exportAsImageScaled h value
			}
			if (and (true == isError) (h == blockForResultImage)) {
				blockForResultImage = nil
				doOneCycle (global 'page')
				waitMSecs 500 // show error bubble briefly before showing menu
				exportAsImageScaled h value true
			}
		}
	}
}

method exportScriptImageWithResult SmallRuntime aBlock {
	topBlock = (topBlock aBlock)
	if (isPrototypeHat topBlock) { return }
	blockForResultImage = topBlock
	if (not (isRunning this topBlock)) {
		evalOnBoard this topBlock
	}
}

// Return values

method returnedValue SmallRuntime msg {
	byteCount = (byteCount msg)
	if (byteCount < 7) { return nil } // incomplete msg

	type = (byteAt msg 6)
	if (1 == type) {
		if (byteCount < 10) { return nil } // incomplete msg
		return (+ ((byteAt msg 10) << 24) ((byteAt msg 9) << 16) ((byteAt msg 8) << 8) (byteAt msg 7))
	} (2 == type) {
		return (stringFromByteRange msg 7 (byteCount msg))
	} (3 == type) {
		return (0 != (byteAt msg 7))
	} (4 == type) {
		if (byteCount < 8) { return nil } // incomplete msg
		total = (((byteAt msg 8) << 8) | (byteAt msg 7))
		if (total == 0) { return '[empty list]' }
		sentItems = (readItems this msg)
		out = (list '[')
		for item sentItems {
			add out (toString item)
			add out ', '
		}
		if ((count out) > 1) { removeLast out }
		if (total > (count sentItems)) {
			add out (join ' ... and ' (total - (count sentItems)) ' more')
		}
		add out ']'
		return (joinStrings out)
	} (5 == type) {
		if (byteCount < 9) { return nil } // incomplete msg
		total = (((byteAt msg 8) << 8) | (byteAt msg 7))
		if (total == 0) { return '(empty byte array)' }
		sentCount = (byteAt msg 9)
		sentCount = (min sentCount (byteCount - 9))
		out = (list '(')
		for i sentCount {
			add out (toString (byteAt msg (9 + i)))
			add out ', '
		}
		if ((count out) > 1) { removeLast out }
		if (total > sentCount) {
			add out (join ' ... and ' (total - sentCount) ' more bytes')
		}
		add out ')'
		return (joinStrings out)
	} else {
		print 'Serial error, type: ' type
		return nil
	}
}

method readItems SmallRuntime msg {
	// Read a sequence of list items from the given value message.

	result = (list)
	byteCount = (byteCount msg)
	if (byteCount < 10) { return result } // corrupted msg
	count = (byteAt msg 9)
	i = 10
	repeat count {
		if (byteCount < (i + 1)) { return result } // corrupted msg
		itemType = (byteAt msg i)
		if (1 == itemType) { // integer
			if (byteCount < (i + 4)) { return result } // corrupted msg
			n = (+ ((byteAt msg (i + 4)) << 24) ((byteAt msg (i + 3)) << 16)
					((byteAt msg (i + 2)) << 8) (byteAt msg (i + 1)))
			add result n
			i += 5
		} (2 == itemType) { // string
			len = (byteAt msg (i + 1))
			if (byteCount < (+ i len 1)) { return result } // corrupted msg
			add result (toString (copyFromTo msg (i + 2) (+ i len 1)))
			i += (len + 2)
		} (3 == itemType) { // boolean
			isTrue = ((byteAt msg (i + 1)) != 0)
			add result isTrue
			i += 2
		} (4 == itemType) { // sublist
			if (byteCount < (i + 3)) { return result } // corrupted msg
			n = (+ ((byteAt msg (i + 2)) << 8) (byteAt msg (i + 1)))
			if (0 != (byteAt msg (i + 3))) {
				print 'skipping sublist with non-zero sent items'
				return result
			}
			add result (join '[' n ' item list]')
			i += 4
		} (5 == itemType) { // bytearray
			if (byteCount < (i + 3)) { return result } // corrupted msg
			n = (+ ((byteAt msg (i + 2)) << 8) (byteAt msg (i + 1)))
			if (0 != (byteAt msg (i + 3))) {
				print 'skipping bytearray with non-zero sent items inside a list'
				return result
			}
			add result (join '(' n ' bytes)')
			i += 4
		} else {
			print 'unknown item type in value message:' itemType
			return result
		}
	}
	return result
}

method showOutputStrings SmallRuntime {
	// For debuggong. Just display incoming characters.
	if (isNil port) { return }
	s = (readSerialPort port)
	if (notNil s) {
		if (isNil recvBuf) { recvBuf = '' }
		recvBuf = (toString recvBuf)
		recvBuf = (join recvBuf s)
		while (notNil (findFirst recvBuf (newline))) {
			i = (findFirst recvBuf (newline))
			out = (substring recvBuf 1 (i - 2))
			recvBuf = (substring recvBuf (i + 1))
			print out
		}
	}
}

// Virtual Machine Installer

method installVM SmallRuntime eraseFlashFlag downloadLatestFlag {
	if ('Browser' == (platform)) {
		installVMInBrowser this eraseFlashFlag downloadLatestFlag
		return
	}
	boards = (collectBoardDrives this)
	if ((count boards) == 1) {
		b = (first boards)
		copyVMToBoard this (first b) (last b)
	} ((count boards) > 1) {
		menu = (menu 'Select board:' this)
		for b boards {
			addItem menu (niceBoardName this b) (action 'copyVMToBoard' this (first b) (last b))
		}
		popUpAtHand menu (global 'page')
	} ((count (portList this)) > 0) {
		if (and (contains (array 'ESP8266' 'ESP32' 'Citilab ED1' 'M5Stack-Core' 'M5StickC' 'M5StickC+' 'M5Atom-Matrix') boardType)
				(confirm (global 'page') nil (join (localized 'Use board type ') boardType '?'))) {
			flashVM this boardType eraseFlashFlag downloadLatestFlag
		} ('RP2040' == boardType) {
			rp2040ResetMessage this
			return
		} else {
			disconnected = true
			closePort this
			menu = (menu 'Select board type:' this)
			for boardName (array 'ESP8266' 'ESP32' 'Citilab ED1' 'M5Stack-Core' 'M5StickC' 'M5StickC+' 'M5Atom-Matrix') {
				eraseFlashFlag = true
				addItem menu boardName (action 'flashVM' this boardName eraseFlashFlag downloadLatestFlag)
			}
			addLine menu
			addItem menu 'Adafruit Board' (action 'adaFruitResetMessage' this)
			addItem menu 'RP2040 (Pico)' (action 'rp2040ResetMessage' this)
			popUpAtHand menu (global 'page')
		}
	} else {
		(inform (join
			(localized 'No boards found; is your board plugged in?') (newline)
			(localized 'For Adafruit boards, double-click reset button and try again.'))
			'No boards found')
	}
}

method niceBoardName SmallRuntime board {
	name = (first board)
	if (beginsWith name 'MICROBIT') {
		return 'micro:bit'
	} (beginsWith name 'MINI') {
		return 'Calliope mini'
	} (beginsWith name 'CPLAYBOOT') {
		return 'Circuit Playground Express'
	} (beginsWith name 'CPLAYBTBOOT') {
		return 'Circuit Playground Bluefruit'
	} (beginsWith name 'CLUE') {
		return 'Clue'
	} (beginsWith name 'METRO') {
		return 'Metro M0'
	} (beginsWith name 'RPI-RP2') {
		return 'Raspberry Pi Pico'
	}
	return name
}

method collectBoardDrives SmallRuntime {
	result = (list)
	if ('Mac' == (platform)) {
		for v (listDirectories '/Volumes') {
			path = (join '/Volumes/' v '/')
			driveName = (getBoardDriveName this path)
			if (notNil driveName) { add result (list driveName path) }
		}
	} ('Linux' == (platform)) {
		for dir (listDirectories '/media') {
			prefix = (join '/media/' dir)
			for v (listDirectories prefix) {
				path = (join prefix '/' v '/')
				driveName = (getBoardDriveName this path)
				if (notNil driveName) { add result (list driveName path) }
			}
		}
	} ('Win' == (platform)) {
		for letter (range 65 90) {
			drive = (join (string letter) ':')
			driveName = (getBoardDriveName this drive)
			if (notNil driveName) { add result (list driveName drive) }
		}
	}
	return result
}

method getBoardDriveName SmallRuntime path {
	for fn (listFiles path) {
		if ('MICROBIT.HTM' == fn) {
			contents = (readFile (join path fn))
			return 'MICROBIT' }
		if (or ('MINI.HTM' == fn) ('Calliope.html' == fn)) { return 'MINI' }
		if ('INFO_UF2.TXT' == fn) {
			contents = (readFile (join path fn))
			if (notNil (nextMatchIn 'CPlay Express' contents)) { return 'CPLAYBOOT' }
			if (notNil (nextMatchIn 'Circuit Playground nRF52840' contents)) { return 'CPLAYBTBOOT' }
			if (notNil (nextMatchIn 'Adafruit Clue' contents)) { return 'CLUEBOOT' }
			if (notNil (nextMatchIn 'Metro M0' contents)) { return 'METROBOOT' }
			if (notNil (nextMatchIn 'RPI-RP2' contents)) { return 'RPI-RP2' }
		}
	}
	return nil
}

method picoVMFileName SmallRuntime {
	isPicoW = (confirm (global 'page') nil (localized 'Is this a Pico W (WiFi) board?'))
	if isPicoW {
		return 'vm_pico_w.uf2'
	} else {
		return 'vm_pico.uf2'
	}
}

method copyVMToBoard SmallRuntime driveName boardPath {
	// disable auto-connect and close the serial port
	disconnected = true
	closePort this

	if ('MICROBIT' == driveName) {
		vmFileName = 'vm_microbit-universal.hex'
 	} ('MINI' == driveName) {
		vmFileName = 'vm_calliope.hex'
	} ('CPLAYBOOT' == driveName) {
		vmFileName = 'vm_circuitplay.uf2'
	} ('CPLAYBTBOOT' == driveName) {
		vmFileName = 'vm_cplay52.uf2'
	} ('CLUEBOOT' == driveName) {
		vmFileName = 'vm_clue.uf2'
	} ('METROBOOT' == driveName) {
		vmFileName = 'vm_metroM0.uf2'
	} ('RPI-RP2' == driveName) {
		vmFileName = (picoVMFileName this)
	} else {
		print 'unknown drive name in "copyVMToBoard"' // shouldn't happen
		return
	}
	vmData = (readEmbeddedFile (join 'precompiled/' vmFileName) true)
	if (isNil vmData) {
		error (join (localized 'Could not read: ') (join 'precompiled/' vmFileName))
	}
	writeFile (join boardPath vmFileName) vmData
	print 'Installed' (join boardPath vmFileName) (join '(' (byteCount vmData) ' bytes)')
	waitMSecs 2000
	if (isOneOf driveName 'MICROBIT' 'MINI') { waitMSecs 4000 }
	disconnected = false
}

// Browser Virtual Machine Intaller

method installVMInBrowser SmallRuntime eraseFlashFlag downloadLatestFlag {
	if ('micro:bit' == boardType) {
		copyVMToBoardInBrowser this 'micro:bit'
	} ('micro:bit v2' == boardType) {
		copyVMToBoardInBrowser this 'micro:bit v2'
	} ('Calliope' == boardType) {
		copyVMToBoardInBrowser this 'Calliope mini'
	} ('CircuitPlayground' == boardType) {
		copyVMToBoardInBrowser this 'Circuit Playground Express'
	} ('CircuitPlayground Bluefruit' == boardType) {
		copyVMToBoardInBrowser this 'Circuit Playground Bluefruit'
	} ('Clue' == boardType) {
		copyVMToBoardInBrowser this 'Clue'
	} ('RP2040' == boardType) {
		copyVMToBoardInBrowser this 'RP2040 (Pico)'
	} (and
		(isOneOf boardType 'Citilab ED1' 'M5Stack-Core' 'M5StickC' 'M5StickC+' 'M5Atom-Matrix' 'ESP32' 'ESP8266')
		(confirm (global 'page') nil (join (localized 'Use board type ') boardType '?'))) {
			flashVM this boardType eraseFlashFlag downloadLatestFlag
	} else {
		menu = (menu 'Select board type:' (action 'copyVMToBoardInBrowser' this) true)
		addItem menu 'micro:bit'
		addItem menu 'Calliope mini'
		addItem menu 'Circuit Playground Express'
		addItem menu 'Circuit Playground Bluefruit'
		addItem menu 'Clue'
		addItem menu 'Citilab ED1'
		addItem menu 'M5Stack-Core'
		addItem menu 'M5StickC'
		addItem menu 'M5StickC+'
		addItem menu 'M5Atom-Matrix'
		addItem menu 'Metro M0'
		addItem menu 'ESP32'
		addItem menu 'ESP8266'
		addItem menu 'RP2040 (Pico)'
		popUpAtHand menu (global 'page')
	}
}

method flashVMInBrowser SmallRuntime boardName {
	if (isNil port) {
		// prompt user to open the serial port
		selectPort this
		timeout = 10000 // ten seconds
		start = (msecsSinceStart)
		while (and (not (isOpenSerialPort 1)) (((msecsSinceStart) - start) < timeout)) {
			// do UI cycles until serial port is opened or timeout
			doOneCycle (global 'page')
			waitMSecs 10 // refresh screen
		}
	}
	if (isOpenSerialPort 1) {
		port = 1
		flashVM this boardName false false
	}
}

method copyVMToBoardInBrowser SmallRuntime boardName {
	if (isOneOf boardName 'Citilab ED1' 'M5Stack-Core' 'M5StickC' 'M5StickC+' 'M5Atom-Matrix' 'ESP32' 'ESP8266') {
		flashVMInBrowser this boardName
		return
	}

	if ('micro:bit' == boardName) {
		vmFileName = 'vm_microbit-universal.hex'
		driveName = 'MICROBIT'
	} ('micro:bit v2' == boardName) {
		vmFileName = 'vm_microbit-universal.hex'
		driveName = 'MICROBIT'
	} ('Calliope mini' == boardName) {
		vmFileName = 'vm_calliope.hex'
		driveName = 'MINI'
	} ('Circuit Playground Express' == boardName) {
		vmFileName = 'vm_circuitplay.uf2'
		driveName = 'CPLAYBOOT'
	} ('Circuit Playground Bluefruit' == boardName) {
		vmFileName = 'vm_cplay52.uf2'
		driveName = 'CPLAYBTBOOT'
	} ('Clue' == boardName) {
		vmFileName = 'vm_clue.uf2'
		driveName = 'CLUEBOOT'
	} ('Metro M0' == boardName) {
		vmFileName = 'vm_metroM0.uf2'
		driveName = 'METROBOOT'
	} ('RP2040 (Pico)' == boardName) {
		vmFileName = (picoVMFileName this)
		driveName = 'RPI-RP2'
	}

	prefix = ''
	if (endsWith vmFileName '.uf2') {
		if ('RPI-RP2' == driveName) {
			// Extra instruction for RP2040 Pico
			prefix = (join
				prefix
				(localized 'Connect USB cable while holding down the white BOOTSEL button before proceeding.')
				(newline) (newline))
		} else {
			// Extra instruction for Adafruit boards
			prefix = (join
				prefix
				(localized 'Press the reset button on the board twice before proceeding. The NeoPixels should turn green.')
				(newline) (newline))
		}
	}
	msg = (join
		prefix
		(localized 'You will be asked to save the firmware file.')
		(newline)
		(newline)
		(localized 'Select')
		' ' driveName ' '
		(localized 'as the destination drive, then click Save.'))
	response = (inform msg (localized 'Firmware Install'))
	if (isNil response) { return }

	vmData = (readFile (join 'precompiled/' vmFileName) true)
	if (isNil vmData) { return } // could not read file

	// disconnect before updating VM; avoids micro:bit autoconnect issue on Chromebooks
	disconnected = true
	closePort this
	updateIndicator (findMicroBlocksEditor)

	if (endsWith vmFileName '.hex') {
		// for micro:bit, filename must be less than 9 letter before the extension
		vmFileName = 'firmware.hex'
		waitForFirmwareInstall this
	}

	browserWriteFile vmData vmFileName 'vmInstall'

	if (endsWith vmFileName '.uf2') {
		waitMSecs 1000 // leave time for file dialog box to appear before showing next prompt
		if ('RPI-RP2' == driveName) {
			otherReconnectMessage this
		} else {
			adaFruitReconnectMessage this
		}
	}
}

method adaFruitResetMessage SmallRuntime {
	inform (localized 'For Adafruit boards, double-click reset button and try again.')
}

method adaFruitReconnectMessage SmallRuntime {
	msg = (join
		(localized 'When the NeoPixels turn off') ', '
		(localized 'reconnect to the board by clicking the "Connect" button (USB icon).'))
	inform msg
}

method rp2040ResetMessage SmallRuntime {
	inform (localized 'Connect USB cable while holding down the white BOOTSEL button and try again.')
}

method otherReconnectMessage SmallRuntime {
	title = (localized 'Firmware Installed')
	msg = (localized 'Reconnect to the board by clicking the "Connect" button (USB icon).')
	inform (global 'page') msg title nil true
}

method waitForFirmwareInstall SmallRuntime {
	firmwareInstallTimer = nil
	spinner = (newSpinner (action 'firmwareInstallStatus' this) (action 'firmwareInstallDone' this))
	addPart (global 'page') spinner
}

method startFirmwareCountdown SmallRuntime fileName {
	// Called by editor after firmware file is saved.

	if ('_no_file_selected_' == fileName) {
		spinner = (findMorph 'MicroBlocksSpinner')
		if (notNil spinner) { destroy (handler spinner) }
	} else {
		firmwareInstallTimer = (newTimer)
	}
}

method firmwareInstallSecsRemaining SmallRuntime {
	if (isNil firmwareInstallTimer) { return 0 }
	installWaitMSecs = 6000
	if (and ('Browser' == (platform)) (browserIsChromeOS)) {
		installWaitMSecs = 16000
	}
	return (ceiling ((installWaitMSecs - (msecs firmwareInstallTimer)) / 1000))
}

method firmwareInstallStatus SmallRuntime {
	if (isNil firmwareInstallTimer) { return 'Installing firmware...' }
	return (join '' (firmwareInstallSecsRemaining this) ' ' (localized 'seconds remaining') '.')
}

method firmwareInstallDone SmallRuntime {
	if (isNil firmwareInstallTimer) { return false }

	if ((firmwareInstallSecsRemaining this) <= 0) {
		firmwareInstallTimer = nil
		otherReconnectMessage this
		return true
	}
	return false
}

// espressif board flashing

method flasher SmallRuntime { return flasher }

method confirmRemoveFlasher SmallRuntime { // xxx needed?
	ok = (confirm
		(global 'page')
		nil
		(localized 'Are you sure you want to cancel the upload process?'))
	if ok { removeFlasher this }
}

method removeFlasher SmallRuntime {
	destroy flasher
	flasher = nil
}

method flashVM SmallRuntime boardName eraseFlashFlag downloadLatestFlag {
	stopAndSyncScripts this
	if ('Browser' == (platform)) {
		disconnected = true
		flasherPort = port
		port = nil
	} else {
		setPort this 'disconnect'
		flasherPort = nil
	}
	flasher = (newFlasher boardName portName eraseFlashFlag downloadLatestFlag)
	addPart (global 'page') (spinner flasher)
	startFlasher flasher flasherPort
}

// data logging

method lastDataIndex SmallRuntime { return loggedDataNext }

method clearLoggedData SmallRuntime {
	loggedData = (newArray 10000)
	loggedDataNext = 1
	loggedDataCount = 0
}

method addLoggedData SmallRuntime s {
	atPut loggedData loggedDataNext s
	loggedDataNext = ((loggedDataNext % (count loggedData)) + 1)
	if (loggedDataCount < (count loggedData)) { loggedDataCount += 1 }
}

method loggedData SmallRuntime howMany {
	if (or (isNil howMany) (howMany > loggedDataCount)) {
		howMany = loggedDataCount
	}
	result = (newArray howMany)
	start = (loggedDataNext - howMany)
	if (start > 0) {
		replaceArrayRange result 1 howMany loggedData start
	} else {
		tailCount = (- start)
		tailStart = (((count loggedData) - tailCount) + 1)
		replaceArrayRange result 1 tailCount loggedData tailStart
		replaceArrayRange result (tailCount + 1) howMany loggedData 1
	}
	return result
}
