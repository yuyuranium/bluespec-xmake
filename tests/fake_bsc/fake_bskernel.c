int bsprim_fake(void);

int bk_fake_kernel(void) {
    return bsprim_fake() + 1;
}
