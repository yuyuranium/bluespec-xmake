#include <cstdio>

#include "mkTop_systemc.h"

int main() {
    if (bluespec_xmake_fake_systemc() <= 0) {
        return 1;
    }
    std::puts("SYSTEMC_CONSUMER_OK");
    return 0;
}
