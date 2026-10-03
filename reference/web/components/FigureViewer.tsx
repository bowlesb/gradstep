"use client";

import { useState, useEffect, useCallback, useRef } from "react";

export interface Figure {
  id: string;
  figure_number: string | null;
  src: string;
  caption: string | null;
  context: string | null;
  sort_index: number;
}

interface Props {
  paperId: string;
  darkMode: boolean;
  mobile?: boolean;
  onClose: () => void;
  onScrollToFigure?: (figureContext: string) => void;
  initialFigureSrc?: string | null;
}

export default function FigureViewer({
  paperId,
  darkMode,
  mobile,
  onClose,
  onScrollToFigure,
  initialFigureSrc,
}: Props) {
  const [figures, setFigures] = useState<Figure[]>([]);
  const [loading, setLoading] = useState(true);
  const [selectedIndex, setSelectedIndex] = useState<number | null>(null);
  const [imageScale, setImageScale] = useState(1);
  const [imageOffset, setImageOffset] = useState({ x: 0, y: 0 });
  const [isPinching, setIsPinching] = useState(false);
  const [captionExpanded, setCaptionExpanded] = useState(false);
  const lastTouchDist = useRef<number | null>(null);
  const lastTouchCenter = useRef<{ x: number; y: number } | null>(null);
  const imageContainerRef = useRef<HTMLDivElement>(null);
  const imgRef = useRef<HTMLImageElement>(null);
  // Use refs for transform during gestures to avoid re-render storms
  const scaleVal = useRef(1);
  const offsetVal = useRef({ x: 0, y: 0 });
  const rafId = useRef<number>(0);

  useEffect(() => {
    async function load() {
      try {
        const res = await fetch(`/api/papers/${paperId}/figures`);
        const data = await res.json();
        const figs: Figure[] = data.figures || [];
        setFigures(figs);
        // Auto-select figure matching initialFigureSrc
        if (initialFigureSrc && figs.length > 0) {
          const srcFile = initialFigureSrc.split("/").pop()?.split("?")[0] || "";
          const idx = figs.findIndex((f) => {
            const figFile = f.src.split("/").pop()?.split("?")[0] || "";
            return figFile === srcFile || f.src === initialFigureSrc;
          });
          if (idx >= 0) selectFigure(idx);
        }
      } catch {
        /* ignore */
      } finally {
        setLoading(false);
      }
    }
    load();
  }, [paperId]);

  // Reset zoom when changing figure
  const selectFigure = useCallback((index: number | null) => {
    setSelectedIndex(index);
    setImageScale(1);
    setImageOffset({ x: 0, y: 0 });
    scaleVal.current = 1;
    offsetVal.current = { x: 0, y: 0 };
    setCaptionExpanded(false);
  }, []);

  // All touch/wheel handlers use refs + rAF to avoid re-render storms
  const lastTapTime = useRef(0);
  const isPinchingRef = useRef(false);
  const isDraggingRef = useRef(false);
  const lastMousePos = useRef<{ x: number; y: number } | null>(null);

  // Apply transform directly to DOM for smooth 60fps gestures
  const applyTransform = useCallback(() => {
    const img = imgRef.current;
    if (img) {
      img.style.transform = `translate(${offsetVal.current.x}px, ${offsetVal.current.y}px) scale(${scaleVal.current})`;
    }
  }, []);

  // Sync ref values back to React state (for UI that depends on state, like Reset button)
  const syncState = useCallback(() => {
    setImageScale(scaleVal.current);
    setImageOffset({ ...offsetVal.current });
  }, []);

  useEffect(() => {
    const el = imageContainerRef.current;
    if (!el || selectedIndex === null) return;

    function onTouchStart(e: TouchEvent) {
      if (e.touches.length === 2) {
        e.preventDefault();
        isPinchingRef.current = true;
        setIsPinching(true);
        const dx = e.touches[0].clientX - e.touches[1].clientX;
        const dy = e.touches[0].clientY - e.touches[1].clientY;
        lastTouchDist.current = Math.hypot(dx, dy);
        lastTouchCenter.current = {
          x: (e.touches[0].clientX + e.touches[1].clientX) / 2,
          y: (e.touches[0].clientY + e.touches[1].clientY) / 2,
        };
      } else if (e.touches.length === 1) {
        const now = Date.now();
        if (now - lastTapTime.current < 300) {
          e.preventDefault();
          if (scaleVal.current > 1) {
            scaleVal.current = 1;
            offsetVal.current = { x: 0, y: 0 };
          } else {
            scaleVal.current = 2.5;
            const touch = e.touches[0];
            const rect = el!.getBoundingClientRect();
            offsetVal.current = {
              x: -(touch.clientX - rect.left - rect.width / 2) * 1.5,
              y: -(touch.clientY - rect.top - rect.height / 2) * 1.5,
            };
          }
          applyTransform();
          syncState();
        }
        lastTapTime.current = now;
        lastTouchCenter.current = { x: e.touches[0].clientX, y: e.touches[0].clientY };
      }
    }

    function onTouchMove(e: TouchEvent) {
      if (e.touches.length === 2 && lastTouchDist.current !== null) {
        e.preventDefault();
        const dx = e.touches[0].clientX - e.touches[1].clientX;
        const dy = e.touches[0].clientY - e.touches[1].clientY;
        const dist = Math.hypot(dx, dy);
        const scaleDelta = dist / lastTouchDist.current;
        lastTouchDist.current = dist;

        scaleVal.current = Math.max(0.5, Math.min(5, scaleVal.current * scaleDelta));

        const cx = (e.touches[0].clientX + e.touches[1].clientX) / 2;
        const cy = (e.touches[0].clientY + e.touches[1].clientY) / 2;
        if (lastTouchCenter.current) {
          offsetVal.current = {
            x: offsetVal.current.x + (cx - lastTouchCenter.current.x),
            y: offsetVal.current.y + (cy - lastTouchCenter.current.y),
          };
        }
        lastTouchCenter.current = { x: cx, y: cy };
        cancelAnimationFrame(rafId.current);
        rafId.current = requestAnimationFrame(applyTransform);
      } else if (e.touches.length === 1 && scaleVal.current > 1 && !isPinchingRef.current) {
        e.preventDefault();
        const touch = e.touches[0];
        if (lastTouchCenter.current) {
          offsetVal.current = {
            x: offsetVal.current.x + (touch.clientX - lastTouchCenter.current.x),
            y: offsetVal.current.y + (touch.clientY - lastTouchCenter.current.y),
          };
        }
        lastTouchCenter.current = { x: touch.clientX, y: touch.clientY };
        cancelAnimationFrame(rafId.current);
        rafId.current = requestAnimationFrame(applyTransform);
      }
    }

    function onTouchEnd(e: TouchEvent) {
      if (e.touches.length < 2) {
        lastTouchDist.current = null;
        isPinchingRef.current = false;
        setIsPinching(false);
        syncState();
      }
      if (e.touches.length === 1) {
        lastTouchCenter.current = { x: e.touches[0].clientX, y: e.touches[0].clientY };
      } else if (e.touches.length === 0) {
        lastTouchCenter.current = null;
      }
    }

    function onWheel(e: WheelEvent) {
      e.preventDefault();
      const delta = e.deltaY > 0 ? 0.9 : 1.1;
      scaleVal.current = Math.max(0.5, Math.min(5, scaleVal.current * delta));
      cancelAnimationFrame(rafId.current);
      rafId.current = requestAnimationFrame(() => {
        applyTransform();
        syncState();
      });
    }

    // Mouse drag for desktop panning when zoomed
    function onMouseDown(e: MouseEvent) {
      if (scaleVal.current > 1) {
        isDraggingRef.current = true;
        lastMousePos.current = { x: e.clientX, y: e.clientY };
        el!.style.cursor = "grabbing";
        e.preventDefault();
      }
    }
    function onMouseMove(e: MouseEvent) {
      if (!isDraggingRef.current || !lastMousePos.current) return;
      e.preventDefault();
      offsetVal.current = {
        x: offsetVal.current.x + (e.clientX - lastMousePos.current.x),
        y: offsetVal.current.y + (e.clientY - lastMousePos.current.y),
      };
      lastMousePos.current = { x: e.clientX, y: e.clientY };
      cancelAnimationFrame(rafId.current);
      rafId.current = requestAnimationFrame(applyTransform);
    }
    function onMouseUp() {
      if (isDraggingRef.current) {
        isDraggingRef.current = false;
        lastMousePos.current = null;
        el!.style.cursor = scaleVal.current > 1 ? "grab" : "";
        syncState();
      }
    }

    el.addEventListener("touchstart", onTouchStart, { passive: false });
    el.addEventListener("touchmove", onTouchMove, { passive: false });
    el.addEventListener("touchend", onTouchEnd, { passive: false });
    el.addEventListener("wheel", onWheel, { passive: false });
    el.addEventListener("mousedown", onMouseDown);
    window.addEventListener("mousemove", onMouseMove);
    window.addEventListener("mouseup", onMouseUp);
    return () => {
      el.removeEventListener("touchstart", onTouchStart);
      el.removeEventListener("touchmove", onTouchMove);
      el.removeEventListener("touchend", onTouchEnd);
      el.removeEventListener("wheel", onWheel);
      el.removeEventListener("mousedown", onMouseDown);
      window.removeEventListener("mousemove", onMouseMove);
      window.removeEventListener("mouseup", onMouseUp);
      cancelAnimationFrame(rafId.current);
    };
  }, [selectedIndex, applyTransform, syncState]);

  // Escape key: if viewing a single figure go back to gallery, otherwise close
  useEffect(() => {
    function handleKeyDown(e: KeyboardEvent) {
      if (e.key === "Escape") {
        if (captionExpanded) {
          setCaptionExpanded(false);
        } else if (selectedIndex !== null) {
          selectFigure(null);
        } else {
          onClose();
        }
      }
    }
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [selectedIndex, captionExpanded, selectFigure, onClose]);

  const bg = darkMode ? "#0f0f0f" : "#ffffff";
  const textColor = darkMode ? "#e4e4e7" : "#18181b";
  const textSecondary = darkMode ? "#a1a1aa" : "#71717a";
  const borderColor = darkMode ? "#27272a" : "#e4e4e7";
  const cardBg = darkMode ? "#1a1a1e" : "#f4f4f5";

  if (loading) {
    return (
      <div
        style={{
          position: "fixed",
          inset: 0,
          zIndex: 50,
          background: bg,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          color: textSecondary,
        }}
      >
        Loading figures...
      </div>
    );
  }

  // Full-screen single figure view with zoom
  if (selectedIndex !== null && figures[selectedIndex]) {
    const fig = figures[selectedIndex];
    return (
      <div
        style={{
          position: "fixed",
          inset: 0,
          zIndex: 50,
          background: darkMode ? "#000" : "#fff",
          display: "flex",
          flexDirection: "column",
        }}
      >
        {/* Header bar */}
        <div
          style={{
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
            padding: mobile ? "env(safe-area-inset-top, 8px) 12px 8px 12px" : "8px 16px",
            borderBottom: `1px solid ${borderColor}`,
            background: bg,
            flexShrink: 0,
            minHeight: 44,
          }}
        >
          <button
            onClick={() => selectFigure(null)}
            style={{
              background: "transparent",
              border: "none",
              color: "#6366f1",
              fontSize: "14px",
              fontWeight: 500,
              cursor: "pointer",
              padding: "8px 4px",
              display: "flex",
              alignItems: "center",
              gap: 4,
            }}
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <polyline points="15 18 9 12 15 6" />
            </svg>
            All Figures
          </button>
          <span style={{ color: textSecondary, fontSize: "13px" }}>
            {fig.figure_number ? `Figure ${fig.figure_number}` : `${selectedIndex + 1} / ${figures.length}`}
          </span>
          <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
            {imageScale > 1 && (
              <button
                onClick={() => { scaleVal.current = 1; offsetVal.current = { x: 0, y: 0 }; setImageScale(1); setImageOffset({ x: 0, y: 0 }); }}
                style={{
                  background: "transparent",
                  border: "none",
                  color: textSecondary,
                  fontSize: "12px",
                  cursor: "pointer",
                  padding: "4px",
                }}
              >
                Reset
              </button>
            )}
          </div>
        </div>

        {/* Image area with zoom — takes all remaining space */}
        <div
          ref={imageContainerRef}
          onClick={() => { if (captionExpanded) setCaptionExpanded(false); }}
          style={{
            flex: 1,
            overflow: "hidden",
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            background: darkMode ? "#000" : "#f8f8f8",
            touchAction: "none",
            position: "relative",
            cursor: imageScale > 1 ? "grab" : "default",
          }}
        >
          <img
            ref={imgRef}
            src={fig.src}
            alt={fig.caption || `Figure ${fig.figure_number || selectedIndex + 1}`}
            draggable={false}
            style={{
              maxWidth: "100%",
              maxHeight: "100%",
              objectFit: "contain",
              transform: `translate(${imageOffset.x}px, ${imageOffset.y}px) scale(${imageScale})`,
              transformOrigin: "center center",
              transition: "none",
              userSelect: "none",
              WebkitUserSelect: "none",
            }}
          />

          {/* Prev / Next arrows — hidden when zoomed to avoid confusion with pan gestures */}
          {imageScale <= 1 && (
            <>
              <button
                onClick={() => selectedIndex > 0 && selectFigure(selectedIndex - 1)}
                style={{
                  position: "absolute",
                  left: 4,
                  top: "50%",
                  transform: "translateY(-50%)",
                  background: darkMode ? "rgba(0,0,0,0.5)" : "rgba(255,255,255,0.7)",
                  border: "none",
                  borderRadius: "50%",
                  width: 36,
                  height: 36,
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "center",
                  cursor: "pointer",
                  opacity: selectedIndex <= 0 ? 0 : 0.8,
                  pointerEvents: selectedIndex <= 0 ? "none" : "auto",
                  backdropFilter: "blur(4px)",
                  color: darkMode ? "#e4e4e7" : "#18181b",
                }}
              >
                <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                  <polyline points="15 18 9 12 15 6" />
                </svg>
              </button>
              <button
                onClick={() => selectedIndex < figures.length - 1 && selectFigure(selectedIndex + 1)}
                style={{
                  position: "absolute",
                  right: 4,
                  top: "50%",
                  transform: "translateY(-50%)",
                  background: darkMode ? "rgba(0,0,0,0.5)" : "rgba(255,255,255,0.7)",
                  border: "none",
                  borderRadius: "50%",
                  width: 36,
                  height: 36,
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "center",
                  cursor: "pointer",
                  opacity: selectedIndex >= figures.length - 1 ? 0 : 0.8,
                  pointerEvents: selectedIndex >= figures.length - 1 ? "none" : "auto",
                  backdropFilter: "blur(4px)",
                  color: darkMode ? "#e4e4e7" : "#18181b",
                }}
              >
                <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round">
                  <polyline points="9 6 15 12 9 18" />
                </svg>
              </button>
            </>
          )}

          {/* Zoom hint — only when not zoomed */}
          {imageScale <= 1 && !captionExpanded && (
            <div style={{
              position: "absolute",
              bottom: fig.caption ? 56 : 12,
              left: "50%",
              transform: "translateX(-50%)",
              background: darkMode ? "rgba(0,0,0,0.7)" : "rgba(255,255,255,0.8)",
              borderRadius: "8px",
              padding: "4px 10px",
              fontSize: "11px",
              color: textSecondary,
              backdropFilter: "blur(8px)",
              pointerEvents: "none",
            }}>
              {mobile ? "Pinch to zoom · Double-tap to enlarge · Drag to pan" : "Scroll to zoom"}
            </div>
          )}

          {/* Caption peek bar — always visible at bottom of image area if there's a caption */}
          {fig.caption && !captionExpanded && (
            <button
              onClick={() => setCaptionExpanded(true)}
              style={{
                position: "absolute",
                bottom: 0,
                left: 0,
                right: 0,
                background: darkMode ? "rgba(0,0,0,0.85)" : "rgba(255,255,255,0.92)",
                backdropFilter: "blur(12px)",
                WebkitBackdropFilter: "blur(12px)",
                border: "none",
                borderTop: `1px solid ${darkMode ? "rgba(255,255,255,0.1)" : "rgba(0,0,0,0.08)"}`,
                padding: mobile ? "10px 16px" : "10px 24px",
                cursor: "pointer",
                textAlign: "left",
                display: "flex",
                alignItems: "center",
                gap: 8,
              }}
            >
              <div style={{ flex: 1, minWidth: 0 }}>
                <p style={{
                  margin: 0,
                  fontSize: "13px",
                  lineHeight: 1.4,
                  color: textColor,
                  overflow: "hidden",
                  textOverflow: "ellipsis",
                  whiteSpace: "nowrap",
                }}>
                  {fig.caption || ""}
                </p>
              </div>
              <svg
                width="16" height="16" viewBox="0 0 24 24" fill="none"
                stroke={textSecondary} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"
                style={{ flexShrink: 0 }}
              >
                <polyline points="18 15 12 9 6 15" />
              </svg>
            </button>
          )}
        </div>

        {/* Expanded caption sheet — overlays bottom portion of screen */}
        {captionExpanded && fig.caption && (
          <div
            style={{
              position: "absolute",
              bottom: 0,
              left: 0,
              right: 0,
              maxHeight: "60vh",
              background: darkMode ? "rgba(15,15,15,0.97)" : "rgba(255,255,255,0.97)",
              backdropFilter: "blur(16px)",
              WebkitBackdropFilter: "blur(16px)",
              borderTop: `1px solid ${borderColor}`,
              borderRadius: "16px 16px 0 0",
              boxShadow: "0 -4px 24px rgba(0,0,0,0.15)",
              display: "flex",
              flexDirection: "column",
              overflow: "hidden",
              zIndex: 5,
            }}
          >
            {/* Drag handle + collapse button */}
            <div
              onClick={() => setCaptionExpanded(false)}
              style={{
                padding: "8px 16px 4px",
                cursor: "pointer",
                display: "flex",
                flexDirection: "column",
                alignItems: "center",
                flexShrink: 0,
              }}
            >
              <div style={{
                width: 36,
                height: 4,
                borderRadius: 2,
                background: darkMode ? "#3f3f46" : "#d4d4d8",
                marginBottom: 8,
              }} />
            </div>

            {/* Scrollable caption content */}
            <div style={{
              flex: 1,
              overflowY: "auto",
              padding: mobile ? "0 16px 16px" : "0 24px 20px",
              WebkitOverflowScrolling: "touch",
            }}>
              {/* Figure label */}
              <div style={{
                fontSize: "12px",
                fontWeight: 600,
                color: "#6366f1",
                marginBottom: 6,
                textTransform: "uppercase",
                letterSpacing: "0.3px",
              }}>
                {fig.figure_number ? `Figure ${fig.figure_number}` : `Figure ${selectedIndex + 1}`}
              </div>

              {/* Caption */}
              {fig.caption && (
                <p style={{
                  margin: "0 0 12px 0",
                  fontSize: "15px",
                  lineHeight: 1.6,
                  color: textColor,
                }}>
                  {fig.caption}
                </p>
              )}

              {/* "Go to in paper" action */}
              {onScrollToFigure && (fig.caption || fig.context) && (
                <button
                  onClick={() => {
                    const searchText = (fig.caption || fig.context || "").slice(0, 80);
                    onScrollToFigure(searchText);
                  }}
                  style={{
                    marginTop: 14,
                    background: darkMode ? "#1e1e2e" : "#f0f0ff",
                    border: `1px solid ${darkMode ? "#3f3f60" : "#c7c7f0"}`,
                    borderRadius: "10px",
                    padding: "10px 14px",
                    cursor: "pointer",
                    color: "#6366f1",
                    fontSize: "14px",
                    fontWeight: 500,
                    display: "flex",
                    alignItems: "center",
                    gap: 8,
                    width: "100%",
                    justifyContent: "center",
                  }}
                >
                  <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
                    <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" />
                    <polyline points="14 2 14 8 20 8" />
                  </svg>
                  Go to figure in paper
                </button>
              )}
            </div>
          </div>
        )}
      </div>
    );
  }

  // Gallery view — grid of figure thumbnails
  return (
    <div
      style={{
        position: "fixed",
        inset: 0,
        zIndex: 50,
        background: bg,
        display: "flex",
        flexDirection: "column",
        overflow: "hidden",
      }}
    >
      {/* Header */}
      <div
        style={{
          display: "flex",
          alignItems: "center",
          justifyContent: "space-between",
          padding: mobile ? "env(safe-area-inset-top, 8px) 12px 8px 12px" : "12px 20px",
          borderBottom: `1px solid ${borderColor}`,
          flexShrink: 0,
          minHeight: 44,
        }}
      >
        <div>
          <h2 style={{
            margin: 0,
            fontSize: "17px",
            fontWeight: 600,
            color: textColor,
          }}>
            Figures
          </h2>
          <span style={{ fontSize: "12px", color: textSecondary }}>
            {figures.length} figure{figures.length !== 1 ? "s" : ""} found
          </span>
        </div>
        <button
          onClick={onClose}
          style={{
            background: "transparent",
            border: "none",
            cursor: "pointer",
            color: textSecondary,
            padding: "8px",
            display: "flex",
            alignItems: "center",
          }}
        >
          <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
            <line x1="18" y1="6" x2="6" y2="18" />
            <line x1="6" y1="6" x2="18" y2="18" />
          </svg>
        </button>
      </div>

      {/* Figure list */}
      <div
        style={{
          flex: 1,
          overflowY: "auto",
          padding: mobile ? "8px" : "12px 20px",
          WebkitOverflowScrolling: "touch",
        }}
      >
        {figures.length === 0 ? (
          <div style={{
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            height: "60%",
            color: textSecondary,
            fontSize: "14px",
            textAlign: "center",
            padding: "20px",
          }}>
            No figures found in this paper.<br />
            Figures are automatically extracted from images in the PDF.
          </div>
        ) : (
          <div style={{
            display: "grid",
            gridTemplateColumns: mobile ? "1fr" : "repeat(auto-fill, minmax(280px, 1fr))",
            gap: mobile ? "8px" : "12px",
          }}>
            {figures.map((fig, i) => (
              <button
                key={fig.id}
                onClick={() => selectFigure(i)}
                style={{
                  background: cardBg,
                  border: `1px solid ${borderColor}`,
                  borderRadius: "12px",
                  padding: 0,
                  cursor: "pointer",
                  overflow: "hidden",
                  textAlign: "left",
                  display: "flex",
                  flexDirection: "column",
                  transition: "transform 0.1s, box-shadow 0.1s",
                }}
              >
                {/* Thumbnail */}
                <div style={{
                  width: "100%",
                  height: mobile ? "160px" : "180px",
                  overflow: "hidden",
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "center",
                  background: darkMode ? "#111" : "#fafafa",
                }}>
                  <img
                    src={fig.src}
                    alt={fig.caption || `Figure ${fig.figure_number || i + 1}`}
                    loading="lazy"
                    style={{
                      maxWidth: "100%",
                      maxHeight: "100%",
                      objectFit: "contain",
                    }}
                  />
                </div>
                {/* Label + caption */}
                <div style={{ padding: "10px 12px" }}>
                  <div style={{
                    fontSize: "13px",
                    fontWeight: 600,
                    color: "#6366f1",
                    marginBottom: fig.caption ? 4 : 0,
                  }}>
                    {fig.figure_number ? `Figure ${fig.figure_number}` : `Figure ${i + 1}`}
                  </div>
                  {fig.caption && (
                    <div style={{
                      fontSize: "12px",
                      color: textSecondary,
                      lineHeight: 1.4,
                      display: "-webkit-box",
                      WebkitLineClamp: 3,
                      WebkitBoxOrient: "vertical",
                      overflow: "hidden",
                    }}>
                      {fig.caption}
                    </div>
                  )}
                </div>
              </button>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

const navBtnStyle: React.CSSProperties = {
  background: "transparent",
  border: "none",
  cursor: "pointer",
  padding: "8px",
  display: "flex",
  alignItems: "center",
  gap: 4,
  fontSize: "14px",
  fontWeight: 500,
};
