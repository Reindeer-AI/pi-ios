// python3 and python as shell commands (commandDictionary: MAIN, pimobile_python). CPython reads a program given on
// standard input (`python3 - <<EOF`, `cat x.py | python3`) from the process's stdin, which is not the command's. This
// copies the command's input to a file and runs that, and answers --version on the command's output; any other
// invocation goes straight to CPython's Py_BytesMain.
// Objective-C so that the function stays in the app binary for ios_system to find (Swift removes unreferenced
// functions from apps).

@import Foundation;
@import ios_system;
#include <dlfcn.h>
#include <pthread.h>

typedef int (*PythonMain)(int, char **);
typedef const char *(*PythonVersion)(void);
typedef int (*PythonGILEnsure)(void);
typedef void (*PythonGILRelease)(int);
typedef int (*PythonSetAsyncExc)(unsigned long, void *);

/// The thread running a python3 command, or 0 (commands run one at a time).
static _Atomic unsigned long runningThread;

static void *python(void) {
    static void *handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Frameworks/Python.framework/Python"];
        handle = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
    });
    return handle;
}

/// -V/--version (before any program): CPython prints the version to the process's stdout, not the command's.
static int versionRequest(int argc, char **argv) {
    for (int index = 1; index < argc && argv[index][0] == '-'; index++) {
        if (strcmp(argv[index], "-V") == 0 || strcmp(argv[index], "--version") == 0) return 1;
        if (strcmp(argv[index], "-c") == 0 || strcmp(argv[index], "-m") == 0) return 0;
    }
    return 0;
}

/// Where the program's path goes when the program comes from standard input: the index of `-`, or argc when no program
/// is named. -1 when -c, -m, or a script names the program.
static int standardInputProgramIndex(int argc, char **argv) {
    int index = 1;
    while (index < argc) {
        const char *argument = argv[index];
        if (strcmp(argument, "-") == 0) return index;
        if (strcmp(argument, "--") == 0) return index + 1 < argc ? -1 : argc;
        if (argument[0] != '-') return -1;
        if (argument[1] == '-') {
            index += 1;
            continue;
        }
        // Short options, possibly combined (-uc): -c and -m name the program; -W and -X take a value.
        int skipsValue = 0;
        for (const char *flag = argument + 1; *flag; flag++) {
            if (*flag == 'c' || *flag == 'm') return -1;
            if (*flag == 'W' || *flag == 'X') {
                skipsValue = flag[1] == '\0';
                break;
            }
        }
        index += skipsValue ? 2 : 1;
    }
    return argc;
}

/// Stop: CPython runs inside the app, on the command's thread, so cancelling that thread does not reach a program busy
/// in Python code, and Ctrl-C's route (a signal for CPython's main thread) is not this thread either: the interpreter
/// stays initialized from an earlier command. PyThreadState_SetAsyncExc raises SystemExit in this command's thread at its
/// next bytecode: it unwinds like Ctrl-C's KeyboardInterrupt (finally blocks run; `except Exception` does not catch it),
/// but an unhandled KeyboardInterrupt makes CPython re-raise SIGINT on its process, which here is the app.
/// Returns its thread when a python3 command was running (and is now interrupted), 0 when none was.
__attribute__((used, visibility("default")))
unsigned long pimobile_python_interrupt(void) {
    unsigned long thread = runningThread;
    void *handle = python();
    if (thread == 0 || handle == NULL) return 0;
    PythonGILEnsure ensure = (PythonGILEnsure)dlsym(handle, "PyGILState_Ensure");
    PythonGILRelease release = (PythonGILRelease)dlsym(handle, "PyGILState_Release");
    PythonSetAsyncExc raise = (PythonSetAsyncExc)dlsym(handle, "PyThreadState_SetAsyncExc");
    void **systemExit = (void **)dlsym(handle, "PyExc_SystemExit");
    if (!ensure || !release || !raise || !systemExit) return 0;
    int state = ensure();
    if (runningThread == thread) raise(thread, *systemExit);
    release(state);
    return thread;
}

static int runPython(PythonMain main, int argc, char **argv) {
    runningThread = (unsigned long)pthread_self();
    int status = main(argc, argv);
    runningThread = 0;
    return status;
}

__attribute__((used, visibility("default")))
int pimobile_python(int argc, char **argv) {
    void *handle = python();
    PythonMain main = handle ? (PythonMain)dlsym(handle, "Py_BytesMain") : NULL;
    if (main == NULL) {
        fprintf(ios_stderr(), "python3: Python.framework is missing from the app bundle\n");
        return 127;
    }
    if (versionRequest(argc, argv)) {
        const char *version = ((PythonVersion)dlsym(handle, "Py_GetVersion"))();
        fprintf(ios_stdout(), "Python %.*s\n", (int)strcspn(version, " "), version);
        return 0;
    }
    int index = standardInputProgramIndex(argc, argv);
    if (index < 0) return runPython(main, argc, argv);

    char *program;
    @autoreleasepool {
        NSString *name = [NSString stringWithFormat:@"pi-python-%@.py", NSUUID.UUID.UUIDString];
        program = strdup([NSTemporaryDirectory() stringByAppendingPathComponent:name].fileSystemRepresentation);
    }
    FILE *output = fopen(program, "w");
    if (output == NULL) {
        fprintf(ios_stderr(), "python3: cannot write the program from standard input\n");
        free(program);
        return 1;
    }
    FILE *input = ios_stdin();
    char buffer[65536];
    size_t count;
    while (input && (count = fread(buffer, 1, sizeof buffer, input)) > 0) fwrite(buffer, 1, count, output);
    fclose(output);

    int programArgc = index < argc ? argc : argc + 1;
    char **programArgv = calloc(programArgc + 1, sizeof(char *));
    for (int i = 0; i < argc; i++) programArgv[i] = argv[i];
    programArgv[index] = program;
    int status = runPython(main, programArgc, programArgv);
    free(programArgv);
    unlink(program);
    free(program);
    return status;
}
