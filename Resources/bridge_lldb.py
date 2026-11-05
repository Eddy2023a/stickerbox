"""Install the search-only bridge inside the user's QQ debug copy."""
from pathlib import Path
import lldb

ROOT = Path(__file__).resolve().parent


def install(frame, env):
    process = frame.GetThread().GetProcess()
    error = lldb.SBError()
    options = lldb.SBExpressionOptions()
    options.SetLanguage(lldb.eLanguageTypeC_plus_plus)
    options.SetIgnoreBreakpoints(True)
    options.SetTrapExceptions(False)
    options.SetUnwindOnError(True)
    options.SetTimeoutInMicroSeconds(5000000)
    allocations = []
    scope_open = False

    def allocate(size):
        address = process.AllocateMemory(size, lldb.ePermissionsReadable | lldb.ePermissionsWritable, error)
        if error.Fail():
            raise RuntimeError(str(error))
        allocations.append(address)
        return address

    def call(expression):
        value = frame.EvaluateExpression(expression, options)
        if value.GetError().Fail():
            raise RuntimeError(str(value.GetError()))
        return value.GetValueAsSigned()

    try:
        source = (ROOT / 'emoji-bridge.js').read_bytes()
        code = allocate(len(source) + 1)
        process.WriteMemory(code, source + b'\0', error)
        slots = allocate(48)
        status = call(f'((int(*)(void*,void**))napi_open_handle_scope)((void*){env},(void**){slots+32})')
        if status:
            raise RuntimeError('Could not enter Node handle scope')
        scope_open = True
        status = call(f'((int(*)(void*,const char*,unsigned long,void**))napi_create_string_utf8)((void*){env},(const char*){code},{len(source)},(void**){slots})')
        if status:
            raise RuntimeError('Could not prepare bridge script')
        status = call(f'((int(*)(void*,void*,void**))napi_run_script)((void*){env},*(void**){slots},(void**){slots+8})')
        if status == 9:
            call(f'((int(*)(void*,void**))napi_get_and_clear_last_exception)((void*){env},(void**){slots+16})')
        if status:
            raise RuntimeError('QQ rejected bridge script: ' + str(status))
        print('STICKERBOX_INSTALLED', flush=True)
    finally:
        if scope_open:
            try:
                call(f'((int(*)(void*,void*))napi_close_handle_scope)((void*){env},*(void**){slots+32})')
            except Exception:
                pass
        for address in allocations:
            process.DeallocateMemory(address)


def on_node(frame, location, internal_dict):
    location.GetBreakpoint().SetEnabled(False)
    try:
        install(frame, frame.FindRegister('x0').GetValueAsUnsigned())
    except Exception as error:
        print('STICKERBOX_ERROR', str(error), flush=True)
    return True


def hook():
    breakpoint = lldb.debugger.GetSelectedTarget().BreakpointCreateByName('napi_create_string_utf8')
    breakpoint.SetScriptCallbackFunction('bridge_lldb.on_node')
    print('STICKERBOX_WAITING', flush=True)
