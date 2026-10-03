"use client";

import { useState, FormEvent } from "react";

interface Props {
  onLogin: (username: string) => void;
  hasUsers: boolean;
}

export default function LoginForm({ onLogin, hasUsers }: Props) {
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);

  async function handleSubmit(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setLoading(true);
    try {
      const res = await fetch("/api/auth/login", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ username, password }),
      });
      const data = await res.json();
      if (!res.ok) {
        setError(data.error || "Login failed");
        return;
      }
      onLogin(data.username);
    } catch {
      setError("Connection error");
    } finally {
      setLoading(false);
    }
  }

  return (
    <div style={{
      minHeight: "100dvh",
      display: "flex",
      alignItems: "center",
      justifyContent: "center",
      background: "var(--bg-primary)",
      padding: "20px",
    }}>
      <div style={{
        width: "100%",
        maxWidth: 360,
        display: "flex",
        flexDirection: "column",
        gap: 20,
      }}>
        {/* Logo / title */}
        <div style={{ textAlign: "center" }}>
          <h1 style={{
            margin: 0,
            fontSize: "22px",
            fontWeight: 700,
            color: "var(--text-primary)",
          }}>
            Paper Reader
          </h1>
          <p style={{
            margin: "6px 0 0",
            fontSize: "14px",
            color: "var(--text-secondary)",
          }}>
            Sign in to continue
          </p>
        </div>

        {!hasUsers && (
          <div style={{
            background: "rgba(234,179,8,0.1)",
            border: "1px solid rgba(234,179,8,0.3)",
            borderRadius: "10px",
            padding: "12px 14px",
            fontSize: "13px",
            lineHeight: 1.5,
            color: "var(--text-primary)",
          }}>
            No users have been created yet. Use the admin panel on your local network to create an account.
          </div>
        )}

        <form onSubmit={handleSubmit} style={{
          display: "flex",
          flexDirection: "column",
          gap: 12,
        }}>
          <input
            type="text"
            placeholder="Username"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
            autoComplete="username"
            autoCapitalize="off"
            autoFocus
            style={inputStyle}
          />
          <input
            type="password"
            placeholder="Password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            autoComplete="current-password"
            style={inputStyle}
          />
          {error && (
            <div style={{
              fontSize: "13px",
              color: "#ef4444",
              padding: "0 2px",
            }}>
              {error}
            </div>
          )}
          <button
            type="submit"
            disabled={loading || !username || !password}
            style={{
              background: "#6366f1",
              color: "white",
              border: "none",
              borderRadius: "10px",
              padding: "12px",
              fontSize: "15px",
              fontWeight: 600,
              cursor: loading ? "wait" : "pointer",
              opacity: loading || !username || !password ? 0.6 : 1,
              transition: "opacity 0.15s",
            }}
          >
            {loading ? "Signing in..." : "Sign In"}
          </button>
        </form>
      </div>
    </div>
  );
}

const inputStyle: React.CSSProperties = {
  background: "var(--bg-secondary)",
  border: "1px solid var(--border)",
  borderRadius: "10px",
  padding: "12px 14px",
  fontSize: "15px",
  color: "var(--text-primary)",
  outline: "none",
  width: "100%",
  boxSizing: "border-box",
};
