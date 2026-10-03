"use client";

interface CollapseHandleProps {
  side: "left" | "right";
  visible: boolean;
  onClick: () => void;
  label?: string;
  touch?: boolean;
}

export default function CollapseHandle({ side, visible, onClick, label, touch }: CollapseHandleProps) {
  return (
    <button
      onClick={onClick}
      title={label || "Expand panel"}
      aria-label={label || "Expand panel"}
      style={{
        position: "absolute",
        top: "50%",
        [side]: 0,
        transform: visible
          ? "translateY(-50%)"
          : side === "left"
            ? "translateY(-50%) translateX(-100%)"
            : "translateY(-50%) translateX(100%)",
        opacity: visible ? 1 : 0,
        width: touch ? 24 : 12,
        height: touch ? 64 : 48,
        border: "none",
        borderRadius: side === "left" ? "0 6px 6px 0" : "6px 0 0 6px",
        background: "var(--resize-handle)",
        cursor: "pointer",
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        zIndex: 50,
        transition: "opacity 0.15s ease, transform 0.15s ease, background 0.15s ease",
        padding: 0,
        color: "var(--text-secondary)",
        fontSize: touch ? 12 : 10,
        writingMode: "vertical-lr",
        letterSpacing: 2,
        lineHeight: 1,
        pointerEvents: visible ? "auto" : "none",
      }}
      onMouseEnter={(e) => {
        e.currentTarget.style.background = "var(--border)";
      }}
      onMouseLeave={(e) => {
        e.currentTarget.style.background = "var(--resize-handle)";
      }}
    >
      ⋮⋮
    </button>
  );
}
