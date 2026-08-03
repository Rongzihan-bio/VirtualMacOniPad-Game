#include <Hypervisor/Hypervisor.h>
#include <inttypes.h>
#include <stdio.h>

int main(void) {
    hv_vcpu_config_t config = hv_vcpu_config_create();
    if (!config) {
        fprintf(stderr, "hv_vcpu_config_create returned NULL\n");
        return 1;
    }
    for (uint64_t reg = 0; reg <= 16; reg++) {
        uint64_t value = 0;
        hv_return_t rc = hv_vcpu_config_get_feature_reg(
            config, (hv_feature_reg_t)reg, &value);
        printf("reg=%" PRIu64 " rc=%d value=0x%016" PRIx64 "\n",
               reg, rc, value);
    }
    return 0;
}
