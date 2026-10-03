"use client";

import { useState, useEffect } from "react";

export type DeviceType = "mobile" | "tablet" | "desktop";

export function useDeviceType(): DeviceType {
  const [device, setDevice] = useState<DeviceType>("desktop");

  useEffect(() => {
    const mobileQuery = window.matchMedia("(max-width: 767px)");
    const tabletQuery = window.matchMedia("(min-width: 768px) and (max-width: 1199px)");

    function update() {
      if (mobileQuery.matches) setDevice("mobile");
      else if (tabletQuery.matches) setDevice("tablet");
      else setDevice("desktop");
    }

    update();

    mobileQuery.addEventListener("change", update);
    tabletQuery.addEventListener("change", update);
    return () => {
      mobileQuery.removeEventListener("change", update);
      tabletQuery.removeEventListener("change", update);
    };
  }, []);

  return device;
}
