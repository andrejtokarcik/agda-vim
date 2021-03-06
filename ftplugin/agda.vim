"setlocal iskeyword=33-126,192-255
setlocal commentstring=--\ %s
setlocal comments=s1fl:{-,mb:\ \ ,ex:-},:--
setlocal wildignore+=*.agdai

" The ReloadSyntax function is reproduced from
" http://wiki.portal.chalmers.se/agda/pmwiki.php?n=Main.VIMEditing
" the remainder is covered by the license described in LICENSE.
function! ReloadSyntax()
    syntax clear
    let f = expand('%:h') . "/." . expand('%:t') . ".vim"
    if filereadable(f)
        exec "source " . escape(f, '*')
    endif
    runtime syntax/agda.vim
endfunction
call ReloadSyntax()

function! Load(quiet)
    " Do nothing.  Overidden below with a Python function if python is supported.
endfunction

augroup AgdaAutoReload
    au!
    au QuickfixCmdPost * call ReloadSyntax()
augroup END
set autowrite

if exists("g:agda_extraincpaths")
    let g:agdavim_agda_includepathlist_unquoted = ['.'] + g:agda_extraincpaths
else
    let g:agdavim_agda_includepathlist_unquoted = ['.']
endif

let g:agdavim_agda_includepathlist = deepcopy(g:agdavim_agda_includepathlist_unquoted)
call map(g:agdavim_agda_includepathlist, ' ''"'' . v:val . ''"'' ')

if !exists("g:agdavim_includeutf8_mappings") || g:agdavim_includeutf8_mappings
    runtime agda-utf8.vim
endif

if !exists("g:agdavim_enable_goto_definition")
    let g:agdavim_enable_goto_definition = 1
endif

set efm=\ \ /%\\&%f:%l\\,%c-%.%#,%E/%\\&%f:%l\\,%c-%.%#,%Z,%C%m,%-G%.%#

" Python 3 is NOT supported.  This code and other changes are left here to
" ease adding future Python 3 support.  Right now the main issue is that
" Python 3 treats strings are sequences of characters rather than sequences of
" bytes which interacts poorly with the fact that the column offsets vim
" returns are byte offsets in the current line.  The code below should run
" under Python 3, but it won't match up the holes correctly if you have
" Unicode characters.
function! s:UsingPython2()
  return 1
  "if has('python')
  "  return 1
  "endif
  "return 0
endfunction

let s:using_python2 = s:UsingPython2()
let s:python_until_eof = s:using_python2 ? 'python << EOF' : 'python3 << EOF'
let s:python_cmd = s:using_python2 ? 'py ' : 'py3 '

if has('python') " || has('python3')

let b:agdavim_status = 'Agda'

function! s:LogAgda(name, text, append)
    let agdawinnr = bufwinnr('__Agda__')
    let prevwinnr = winnr()
    if agdawinnr == -1
        let eventignore_save = &eventignore
        set eventignore=all

        silent keepalt botright split __Agda__
        call ResizeAgdaWindow()

        let &eventignore = eventignore_save
        setlocal noreadonly
        setlocal buftype=nofile
        setlocal bufhidden=hide
        setlocal noswapfile
        setlocal nobuflisted
        setlocal nolist
        setlocal nonumber
        setlocal nowrap
        setlocal textwidth=0
        setlocal nocursorline
        setlocal nocursorcolumn
        setlocal filetype=agda-panel

        if exists('+relativenumber')
            setlocal norelativenumber
        endif
    else
        let eventignore_save = &eventignore
        set eventignore=BufEnter

        execute agdawinnr . 'wincmd w'
        let &eventignore = eventignore_save
    endif

    let lazyredraw_save = &lazyredraw
    set lazyredraw
    let eventignore_save = &eventignore
    set eventignore=all

    let b:agdavim_status = a:name
    if a:append == 'True'
        silent put =a:text
    else
        silent %delete _
        silent 0put =a:text
    endif

    0

    let &lazyredraw = lazyredraw_save
    let &eventignore = eventignore_save

    let eventignore_save = &eventignore
    set eventignore=BufEnter

    execute prevwinnr . 'wincmd w'
    let &eventignore = eventignore_save
endfunction


exec s:python_until_eof
import vim
import re
import subprocess

# start Agda
# TODO: I'm pretty sure this will start an agda process per buffer which is less than desirable...
agda = None
def RestartAgda(version=''):
    global agda
    if agda is not None:
      agda.terminate()
    binary = '-'.join(['agda', version]).rstrip('-')
    agda = subprocess.Popen([binary, '--interaction', '--postfix-projections'],
                            bufsize=1, stdin=subprocess.PIPE, stdout=subprocess.PIPE, universal_newlines=True)

RestartAgda()

goals = {}
annotations = []

agdaVersion = None

DEFAULT_REWRITE_MODE = "AsIs"
rewriteMode = DEFAULT_REWRITE_MODE

def setRewriteMode(mode):
    global rewriteMode
    mode = mode.strip()
    if mode not in ["AsIs", "Normalised", "Simplified", "HeadNormal", "Instantiated"]:
        rewriteMode = DEFAULT_REWRITE_MODE
    else:
        rewriteMode = mode

# This technically needs to turn a string into a Haskell escaped string, buuuut just gonna cheat.
def escape(s):
    return s.replace('\\', '\\\\').replace('"', '\\"').replace('\n','\\n') # keep '\\' case first

# This technically needs to turn a Haskell escaped string into a string, buuuut just gonna cheat.
def unescape(s):
    return s.replace('\\\\','\x00').replace('\\"', '"').replace('\\n','\n').replace('\x00', '\\') # hacktastic

def promptUser(msg):
    vim.command('call inputsave()')
    result = vim.eval('input("%s")' % msg)
    vim.command('call inputrestore()')
    return result

def findGoals(goalList):
    global goals

    vim.command('syn sync fromstart') # TODO: This should become obsolete given good sync rules in the syntax file.

    goals = {}
    lines = vim.current.buffer
    row = 1
    agdaHolehlID = vim.eval('hlID("agdaHole")')
    for line in lines:

        start = 0
        while start != -1:
            qstart = line.find("?", start)
            hstart = line.find("{!", start)
            if qstart == -1:
                start = hstart
            elif hstart == -1:
                start = qstart
            else:
                start = min(hstart, qstart)
            if start != -1:
                start = start + 1

                if vim.eval('synID("%d", "%d", 0)' % (row, start)) == agdaHolehlID:
                    goals[goalList.pop(0)] = (row, start)
            if len(goalList) == 0: break
        if len(goalList) == 0: break
        row = row + 1

    vim.command('syn sync clear') # TODO: This wipes out any sync rules and should be removed if good sync rules are added to the syntax file.

def findGoal(row, col, shouldReload=True):
    global goals
    for item in goals.items():
        if item[1][0] == row and item[1][1] == col:
            return item[0]
    if shouldReload:
        vim.command('call Load(1)')
        return findGoal(row, col, False)
    return None

def getOutput():
    line = agda.stdout.readline()[7:] # get rid of the "Agda2> " prompt
    lines = []
    while not line.startswith('Agda2> cannot read') and line != "":
        lines.append(line)
        line = agda.stdout.readline()
    return lines

def parseVersion(versionString):
    global agdaVersion
    agdaVersion = [int(c) for c in versionString[12:].split('-')[0].split('.')]
    agdaVersion = agdaVersion + [0]*max(0, 4-len(agdaVersion))

HOLE = '?'
INTERACTION = '{!  !}'
def introduceInteractionPoint(s, substrLeft, substrRight=None):
    s = s.replace(substrLeft + HOLE, substrLeft + INTERACTION)
    if substrRight:
        s = s.replace(HOLE + substrRight, INTERACTION + substrRight)
    return s

# This is not very efficient presumably.
def c2b(n):
    return int(vim.eval('byteidx(join(getline(1, "$"), "\n"),%d)' % n))

# See https://github.com/agda/agda/blob/323f58f9b8dad239142ed1dfa0c60338ea2cb157/src/data/emacs-mode/annotation.el#L112
def parseAnnotation(spans):
    global annotations
    anns = re.findall(r'\((\d+) (\d+) \([^\)]*\) \w+ \(\"([^"]*)\" \. (\d+)\)\)', spans)
    # TODO: This is assumed to be in sorted order.
    for ann in anns:
        annotations.append([c2b(int(ann[0])-1), c2b(int(ann[1])-1), ann[2], c2b(int(ann[3]))])

def searchAnnotation(lo, hi, idx):
    global annotations

    if hi == 0: return None

    while hi - lo > 1:
        mid = lo + (hi - lo) // 2
        midOffset = annotations[mid][0]
        if idx < midOffset:
            hi = mid
        else:
            lo = mid

    (loOffset, hiOffset) = annotations[lo][0:2]
    if idx > loOffset and idx <= hiOffset:
        return annotations[lo][2:4]
    else:
        return None

def gotoAnnotation():
    global annotations
    byteOffset = int(vim.eval('line2byte(line(".")) + col(".") - 1'))
    result = searchAnnotation(0, len(annotations), byteOffset)
    if result is None: return
    (file, pos) = result
    targetBuffer = None
    for buffer in vim.buffers:
        if buffer.name == file: targetBuffer = buffer.number

    if targetBuffer is None:
        vim.command('edit %s' % file)
    else:
        vim.command('buffer %s' % targetBuffer)
    vim.command('%dgo' % pos)

def interpretResponse(responses, quiet = False):
    for response in responses:
        infoAndCopy = response.startswith('(agda2-info-action-and-copy ')
        if response.startswith('(agda2-info-action ') or infoAndCopy:
            if quiet and '*Error*' in response: vim.command('cwindow')
            strings = re.findall(r'"((?:[^"\\]|\\.)*)"', response[19:])
            if strings[0] == '*Agda Version*':
                parseVersion(strings[1])
            if quiet: continue
            vim.command('call s:LogAgda("%s","%s","%s")'% (strings[0], strings[1], response.endswith('t)')))
            if infoAndCopy:
                # copy the contents to register `h`
                vim.command('let @h = "%s"' % strings[1].strip())

        elif "(agda2-goals-action '" in response:
            findGoals([int(s) for s in re.findall(r'(\d+)', response[response.index("agda2-goals-action '")+21:])])
        elif "(agda2-make-case-action-extendlam '" in response:
            response = introduceInteractionPoint(response, ' = ')
            cases = re.findall(r'"((?:[^"\\]|\\.)*)"', response[response.index("agda2-make-case-action-extendlam '")+34:])
            col = vim.current.window.cursor[1]
            line = vim.current.line

            # TODO: The following logic is far from perfect.
            # Look for a semicolon ending the previous case.
            correction = 0
            starts = [mo for mo in re.finditer(r';', line[:col])]
            if len(starts) == 0:
                # Look for the starting bracket of the extended lambda..
                correction = 1
                starts = [mo for mo in re.finditer(r'{[^!]', line[:col])]
                if len(starts) == 0:
                    # Assume the case is on a line by itself.
                    correction = 1
                    starts = [mo for mo in re.finditer(r'^[ \t]*', line[:col])]
            start = starts[-1].end() - correction

            # Look for a semicolon ending this case.
            correction = 0
            ends = re.search(r';', line[col:])
            if ends == None:
                # Look for the ending bracket of the extended lambda.
                correction = 1
                ends = re.search(r'[^!]}', line[col:])
                if ends == None:
                    # Assume the case is on a line by itself (or at least has nothing after it).
                    correction = 0
                    ends = re.search(r'[ \t]*$', line[col:])
            end = ends.start() + col + correction

            vim.current.line = line[:start] + " " + "; ".join(cases) + " " + line[end:]
            f = vim.current.buffer.name
            sendCommandLoad(f, quiet)
            break
        elif "(agda2-make-case-action '" in response:
            response = introduceInteractionPoint(response, ' = ')
            cases = re.findall(r'"((?:[^"\\]|\\.)*)"', response[response.index("agda2-make-case-action '")+24:])
            row = vim.current.window.cursor[0]
            prefix = re.match(r'[ \t]*', vim.current.line).group()
            vim.current.buffer[row-1:row] = [prefix + case for case in cases]
            f = vim.current.buffer.name
            sendCommandLoad(f, quiet)
            break
        elif response.startswith('(agda2-give-action '):
            response = introduceInteractionPoint(response, ' ', ' ')
            match = re.search(r'(\d+)\s+"((?:[^"\\]|\\.)*)"', response[19:])
            replaceHole(unescape(match.group(2)))
        # elif response.startswith('(agda2-highlight-clear)'):
            # pass # Maybe do something with this.
        elif response.startswith('(agda2-highlight-add-annotations '):
            parseAnnotation(response)
        else:
            pass # print(response)

def sendCommand(arg, quiet=False):
    vim.command('silent! noautocmd write')
    f = vim.current.buffer.name
    # The x is a really hacky way of getting a consistent final response.  Namely, "cannot read"
    agda.stdin.write('IOTCM "%s" None Direct (%s)\nx\n' % (escape(f), arg))
    interpretResponse(getOutput(), quiet)

def sendCommandLoadHighlightInfo(file, quiet):
    sendCommand('Cmd_load_highlighting_info "%s"' % escape(file), quiet = quiet)

def sendCommandLoad(file, quiet):
    global agdaVersion
    if agdaVersion is None:
        sendCommand('Cmd_show_version', quiet=True)
    if agdaVersion < [2,5,0,0]: # in 2.5 they changed it so Cmd_load takes commandline arguments
        incpaths_str = ",".join(vim.eval("g:agdavim_agda_includepathlist"))
    else:
        incpaths_str = "\"-i\"," + ",\"-i\",".join(vim.eval("g:agdavim_agda_includepathlist"))
    sendCommand('Cmd_load "%s" [%s]' % (escape(file), incpaths_str), quiet = quiet)

#def getIdentifierAtCursor():
#    (r, c) = vim.current.window.cursor
#    line = vim.current.line
#    try:
#        start = re.search(r"[^\s@(){};]+$", line[:c+1]).start()
#        end = re.search(r"^[^\s@(){};]+", line[c:]).end() + c
#    except AttributeError as e:
#        return None
#    return line[start:end]

def replaceHole(replacement):
    rep = replacement.replace('\n', ' ').replace('    ', ';') # TODO: This probably needs to be handled better
    (r, c) = vim.current.window.cursor
    line = vim.current.line
    if line[c] == "?":
        start = c
        end = c+1
    else:
        try:
            mo = None
            for mo in re.finditer(r"{!", line[:min(len(line),c+2)]): pass
            start = mo.start()
            end = re.search(r"!}", line[max(0,c-1):]).end() + max(0,c-1)
        except AttributeError:
            return
    vim.current.line = line[:start] + rep + line[end:]

def getHoleBodyAtCursor():
    (r, c) = vim.current.window.cursor
    line = vim.current.line
    try:
        if line[c] == "?":
            return ("", findGoal(r, c+1))
    except IndexError:
        return None
    try: # handle virtual space better
        mo = None
        for mo in re.finditer(r"{!", line[:min(len(line),c+2)]): pass
        start = mo.start()
        end = re.search(r"!}", line[max(0,c-1):]).end() + max(0,c-1)
    except AttributeError:
        return None
    result = line[start+2:end-2].strip()
    return (result, findGoal(r, start+1))

def getWordAtCursor():
    return vim.eval("expand('<cWORD>')").strip()

EOF

function! AgdaVersion(quiet)
exec s:python_until_eof
import vim
sendCommand('Cmd_show_version', quiet = int(vim.eval('a:quiet')) == 1)
EOF
endfunction

function! Load(quiet)
exec s:python_until_eof
import vim
f = vim.current.buffer.name
sendCommandLoad(f, int(vim.eval('a:quiet')) == 1)
if int(vim.eval('g:agdavim_enable_goto_definition')) == 1:
    sendCommandLoadHighlightInfo(f, int(vim.eval('a:quiet')) == 1)
EOF
endfunction

function! LoadHighlightInfo(quiet)
exec s:python_until_eof
import vim
f = vim.current.buffer.name
sendCommandLoadHighlightInfo(f, int(vim.eval('a:quiet')) == 1)
EOF
endfunction

function! GotoAnnotation()
exec s:python_until_eof
import vim
gotoAnnotation()
EOF
endfunction

function! Give()
exec s:python_until_eof
import vim

result = getHoleBodyAtCursor()

if agdaVersion < [2,5,3,0]:
    useForce = ""
else:
    useForce = "WithoutForce" # or WithForce

if result is None:
    print("No hole under the cursor")
elif result[1] is None:
    print("Goal not loaded")
elif not result[0]:
    sendCommand('Cmd_give %s %d noRange "%s"' % (useForce, result[1], escape(promptUser("Enter expression: "))))
else:
    sendCommand('Cmd_give %s %d noRange "%s"' % (useForce, result[1], escape(result[0])))
EOF
endfunction

function! MakeCase(defnHasParams)
exec s:python_until_eof
import vim
result = getHoleBodyAtCursor()
defnHasParams = int(vim.eval('a:defnHasParams'))
if result is None:
    print("No hole under the cursor")
elif result[1] is None:
    print("Goal not loaded")
elif defnHasParams and not result[0]:
    sendCommand('Cmd_make_case %d noRange "%s"' % (result[1], escape(promptUser("Make case on: "))))
else:
    sendCommand('Cmd_make_case %d noRange "%s"' % (result[1], escape(result[0])))
EOF
endfunction

function! Refine(unfoldAbstract)
exec s:python_until_eof
import vim
result = getHoleBodyAtCursor()
if result is None:
    print("No hole under the cursor")
elif result[1] is None:
    print("Goal not loaded")
else:
    sendCommand('Cmd_refine_or_intro %s %d noRange "%s"' %
                (vim.eval('a:unfoldAbstract'), result[1], escape(result[0])))
EOF
endfunction

function! Auto()
exec s:python_until_eof
import vim
result = getHoleBodyAtCursor()
if result is None:
    print("No hole under the cursor")
elif result[1] is None:
    print("Goal not loaded")
else:
    if agdaVersion < [2,6,0,0]:
        sendCommand('Cmd_auto %d noRange "%s"' % (result[1], escape(result[0]) if result[0] != "?" else ""))
    else:
        sendCommand('Cmd_autoOne %d noRange "%s"' % (result[1], escape(result[0]) if result[0] != "?" else ""))
EOF
endfunction

function! SolveConstraints()
exec s:python_until_eof
import vim
result = getHoleBodyAtCursor()
if result is None:
    print("No hole under the cursor, solving all")
    sendCommand('Cmd_solveAll %s' % rewriteMode)
elif result[1] is None:
    print("Goal not loaded")
else:
    sendCommand('Cmd_solveOne %s %d noRange "%s"' %
                (rewriteMode, result[1], escape(result[0])))
EOF
endfunction

function! Context(mode)
exec s:python_until_eof
import vim
mode = vim.eval('a:mode') or rewriteMode
result = getHoleBodyAtCursor()
if result is None:
    print("No hole under the cursor")
elif result[1] is None:
    print("Goal not loaded")
else:
    sendCommand('Cmd_goal_type_context%s %s %d noRange "%s"' %
                ('_infer' if result[0] else '', mode, result[1], escape(result[0])))
EOF
endfunction

function! Infer()
exec s:python_until_eof
import vim
result = getHoleBodyAtCursor()
if result is None or not result[0]:
    sendCommand('Cmd_infer_toplevel %s "%s"' % (rewriteMode, escape(promptUser("Enter expression: "))))
elif result[1] is None:
    print("Goal not loaded")
else:
    sendCommand('Cmd_infer %s %d noRange "%s"' % (rewriteMode, result[1], escape(result[0])))
EOF
endfunction

" As of 2.5.2, the options are "DefaultCompute", "IgnoreAbstract", "UseShowInstance"
function! Normalize(unfoldAbstract)
exec s:python_until_eof
import vim

unfoldAbstract = vim.eval("a:unfoldAbstract")

if agdaVersion < [2,5,2,0]:
    unfoldAbstract = str(unfoldAbstract == "DefaultCompute")

result = getHoleBodyAtCursor()
if result is None:
    sendCommand('Cmd_compute_toplevel %s "%s"' % (unfoldAbstract, escape(promptUser("Enter expression: "))))
elif result[1] is None:
    print("Goal not loaded")
else:
    sendCommand('Cmd_compute %s %d noRange "%s"' % (unfoldAbstract, result[1], escape(result[0])))
EOF
endfunction

function! WhyInScope(term)
exec s:python_until_eof

termName = vim.eval('a:term')
result = getHoleBodyAtCursor() if termName == '' else None

if result is None:
    termName = getWordAtCursor() if termName == '' else termName
    termName = promptUser("Enter name: ") if termName == '' else termName
    sendCommand('Cmd_why_in_scope_toplevel "%s"' % escape(termName))
elif result[1] is None:
    print("Goal not loaded")
else:
    sendCommand('Cmd_why_in_scope %d noRange "%s"' % (result[1], escape(result[0])))
EOF
endfunction

function! ShowModule(module)
exec s:python_until_eof

moduleName = vim.eval('a:module')
result = getHoleBodyAtCursor() if moduleName == '' else None

if agdaVersion < [2,4,2,0]:
    if result is None:
        moduleName = promptUser("Enter module name: ") if moduleName == '' else moduleName
        sendCommand('Cmd_show_module_contents_toplevel "%s"' % escape(moduleName))
    elif result[1] is None:
        print("Goal not loaded")
    else:
        sendCommand('Cmd_show_module_contents %d noRange "%s"' % (result[1], escape(result[0])))
else:
    if result is None:
        moduleName = promptUser("Enter module name: ") if moduleName == '' else moduleName
        sendCommand('Cmd_show_module_contents_toplevel %s "%s"' % (rewriteMode, escape(moduleName)))
    elif result[1] is None:
        print("Goal not loaded")
    else:
        sendCommand('Cmd_show_module_contents %s %d noRange "%s"' % (rewriteMode, result[1], escape(result[0])))
EOF
endfunction

function! HelperFunction()
exec s:python_until_eof
import vim

result = getHoleBodyAtCursor()

if result is None:
    print("No hole under the cursor")
elif result[1] is None:
    print("Goal not loaded")
elif result[0] == "?":
    sendCommand('Cmd_helper_function %s %d noRange "%s"' % (rewriteMode, result[1], escape(promptUser("Enter name for helper function: "))))
else:
    sendCommand('Cmd_helper_function %s %d noRange "%s"' % (rewriteMode, result[1], escape(result[0])))
EOF
endfunction

function! HideAgdaWindow()
    let agdawinnr = bufwinnr('__Agda__')
    if agdawinnr != -1
        exec 'silent! ' . agdawinnr . 'wincmd c'
    endif
endfunction

function! ResizeAgdaWindow()
    let agdawinnr = bufwinnr('__Agda__')
    if agdawinnr != -1
        exec 'silent! ' . agdawinnr . 'resize 10'
    endif
endfunction

" TODO rename so that all commands start with Agda (like Intero* commands)
command! -nargs=0 Load call Load(0)
command! -nargs=0 AgdaVersion call AgdaVersion(0)
command! -nargs=0 Reload silent! call Load(1) | Metas
command! -nargs=0 RestartAgda exec s:python_cmd "RestartAgda()"
command! -nargs=1 RestartAgdaVersion exec s:python_cmd "RestartAgda('<args>')"
command! -nargs=0 ShowImplicitArguments exec s:python_cmd "sendCommand('ShowImplicitArgs True')"
command! -nargs=0 HideImplicitArguments exec s:python_cmd "sendCommand('ShowImplicitArgs False')"
command! -nargs=0 ToggleImplicitArguments exec s:python_cmd "sendCommand('ToggleImplicitArgs')"
command! -nargs=0 Constraints exec s:python_cmd "sendCommand('Cmd_constraints')"
command! -nargs=0 Metas exec s:python_cmd "sendCommand('Cmd_metas')"
command! -nargs=0 SolveConstraints call SolveConstraints()
command! -nargs=1 ShowModule call ShowModule(<args>)
command! -nargs=1 WhyInScope call WhyInScope(<args>)
command! -nargs=0 SetRewriteModeAsIs exec s:python_cmd "setRewriteMode('AsIs')"
command! -nargs=0 SetRewriteModeNormalised exec s:python_cmd "setRewriteMode('Normalised')"
command! -nargs=0 SetRewriteModeSimplified exec s:python_cmd "setRewriteMode('Simplified')"
command! -nargs=0 SetRewriteModeHeadNormal exec s:python_cmd "setRewriteMode('HeadNormal')"
command! -nargs=0 SetRewriteModeInstantiated exec s:python_cmd "setRewriteMode('Instantiated')"

nnoremap <buffer> <LocalLeader>l :Load<CR>
nnoremap <buffer> <LocalLeader>t :call Infer()<CR>
nnoremap <buffer> <LocalLeader>r :call Refine("False")<CR>
nnoremap <buffer> <LocalLeader>R :call Refine("True")<CR>
nnoremap <buffer> <LocalLeader>g :call Give()<CR>
nnoremap <buffer> <LocalLeader>c :call MakeCase(1)<CR>
nnoremap <buffer> <LocalLeader>a :call Auto()<CR>
nnoremap <buffer> <LocalLeader>e :call Context('')<CR>
nnoremap <buffer> <LocalLeader>E :call Context('Normalised')<CR>
nnoremap <buffer> <LocalLeader>n :call Normalize("IgnoreAbstract")<CR>
nnoremap <buffer> <LocalLeader>N :call Normalize("DefaultCompute")<CR>
nnoremap <buffer> <LocalLeader>M :call ShowModule('')<CR>
nnoremap <buffer> <LocalLeader>y :call WhyInScope('')<CR>
nnoremap <buffer> <LocalLeader>h :call HelperFunction()<CR>
nnoremap <buffer> <LocalLeader>d :call GotoAnnotation()<CR>
nnoremap <buffer> <LocalLeader>m :Metas<CR>

" Insert a skeleton definition for a function
" TODO indent the definition to the same level as the type
" FIXME doesn't work with type signature located at last line
nnoremap <buffer> <LocalLeader>d ^yW}O<c-o>p= ?<esc>:call MakeCase(0)<cr>

" Paste the contents from a copy action (e.g., a helper function's type)
nnoremap <buffer> <LocalLeader>p o<tab><c-o>"h]p<esc>kJ

" Show/reload metas
nnoremap <buffer> <C-e> :Metas<CR>
inoremap <buffer> <C-e> <C-o>:Metas<CR>

" Go to next/previous meta
nnoremap <buffer> <silent> <C-g>  :let _s=@/<CR>/ {!\\| ?<CR>:let @/=_s<CR>2l
inoremap <buffer> <silent> <C-g>  <C-o>:let _s=@/<CR><C-o>/ {!\\| ?<CR><C-o>:let @/=_s<CR><C-o>2l

nnoremap <buffer> <silent> <C-y>  2h:let _s=@/<CR>? {!\\| \?<CR>:let @/=_s<CR>2l
inoremap <buffer> <silent> <C-y>  <C-o>2h<C-o>:let _s=@/<CR><C-o>? {!\\| \?<CR><C-o>:let @/=_s<CR><C-o>2l

"Reload

endif
