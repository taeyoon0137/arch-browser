// Entry point of the CEF helper processes (renderer, GPU, utility). The app bundle script copies this executable into each helper bundle.
#import "CEFBridge.h"

int main(int argc, char *argv[]) {
    return [ARCHCEFRuntime runHelperWithArgc:argc argv:argv];
}
