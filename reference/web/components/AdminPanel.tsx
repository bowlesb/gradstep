"use client";

import { useState, useEffect, FormEvent } from "react";

interface User {
  id: string;
  username: string;
  created_at: string;
}

interface Props {
  onClose: () => void;
}

export default function AdminPanel({ onClose }: Props) {
  const [users, setUsers] = useState<User[]>([]);
  const [loading, setLoading] = useState(true);
  const [newUsername, setNewUsername] = useState("");
  const [newPassword, setNewPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [success, setSuccess] = useState<string | null>(null);
  const [creating, setCreating] = useState(false);
  const [deletingId, setDeletingId] = useState<string | null>(null);

  async function fetchUsers() {
    try {
      const res = await fetch("/api/auth/users");
      const data = await res.json();
      setUsers(data.users || []);
    } catch {
      /* ignore */
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    fetchUsers();
  }, []);

  async function handleCreate(e: FormEvent) {
    e.preventDefault();
    setError(null);
    setSuccess(null);
    setCreating(true);
    try {
      const res = await fetch("/api/auth/users", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ username: newUsername, password: newPassword }),
      });
      const data = await res.json();
      if (!res.ok) {
        setError(data.error || "Failed to create user");
        return;
      }
      setSuccess(`User "${data.username}" created`);
      setNewUsername("");
      setNewPassword("");
      fetchUsers();
      setTimeout(() => setSuccess(null), 3000);
    } catch {
      setError("Connection error");
    } finally {
      setCreating(false);
    }
  }

  async function handleDelete(id: string, username: string) {
    if (!confirm(`Delete user "${username}"? Their sessions will be invalidated.`)) return;
    setDeletingId(id);
    try {
      await fetch(`/api/auth/users?id=${id}`, { method: "DELETE" });
      fetchUsers();
    } catch {
      /* ignore */
    } finally {
      setDeletingId(null);
    }
  }

  return (
    <div style={{
      height: "100vh",
      display: "flex",
      flexDirection: "column",
      background: "var(--bg-primary)",
      overflow: "hidden",
    }}>
      {/* Header */}
      <div style={{
        display: "flex",
        alignItems: "center",
        justifyContent: "space-between",
        padding: "16px 24px",
        borderBottom: "1px solid var(--border)",
        flexShrink: 0,
      }}>
        <div>
          <h2 style={{ margin: 0, fontSize: "18px", fontWeight: 600, color: "var(--text-primary)" }}>
            User Management
          </h2>
          <p style={{ margin: "2px 0 0", fontSize: "13px", color: "var(--text-secondary)" }}>
            Admin — local network only
          </p>
        </div>
        <button
          onClick={onClose}
          style={{
            background: "var(--bg-secondary)",
            border: "1px solid var(--border)",
            borderRadius: "10px",
            padding: "8px 16px",
            cursor: "pointer",
            color: "var(--text-primary)",
            fontSize: "14px",
            fontWeight: 500,
          }}
        >
          Close
        </button>
      </div>

      <div style={{
        flex: 1,
        overflowY: "auto",
        padding: "24px",
        maxWidth: 600,
        margin: "0 auto",
        width: "100%",
        boxSizing: "border-box",
      }}>
        {/* Add user form */}
        <div style={{
          background: "var(--bg-secondary)",
          border: "1px solid var(--border)",
          borderRadius: "12px",
          padding: "20px",
          marginBottom: 24,
        }}>
          <h3 style={{
            margin: "0 0 14px 0",
            fontSize: "15px",
            fontWeight: 600,
            color: "var(--text-primary)",
          }}>
            Add User
          </h3>
          <form onSubmit={handleCreate} style={{ display: "flex", flexDirection: "column", gap: 10 }}>
            <div style={{ display: "flex", gap: 10 }}>
              <input
                type="text"
                placeholder="Username"
                value={newUsername}
                onChange={(e) => setNewUsername(e.target.value)}
                autoCapitalize="off"
                autoComplete="off"
                style={{ ...fieldStyle, flex: 1 }}
              />
              <input
                type="password"
                placeholder="Password (min 6 chars)"
                value={newPassword}
                onChange={(e) => setNewPassword(e.target.value)}
                autoComplete="new-password"
                style={{ ...fieldStyle, flex: 1 }}
              />
            </div>
            <div style={{ display: "flex", alignItems: "center", gap: 12 }}>
              <button
                type="submit"
                disabled={creating || !newUsername || newPassword.length < 6}
                style={{
                  background: "#6366f1",
                  color: "white",
                  border: "none",
                  borderRadius: "8px",
                  padding: "8px 20px",
                  fontSize: "14px",
                  fontWeight: 500,
                  cursor: creating ? "wait" : "pointer",
                  opacity: creating || !newUsername || newPassword.length < 6 ? 0.5 : 1,
                }}
              >
                {creating ? "Creating..." : "Add User"}
              </button>
              {error && <span style={{ fontSize: "13px", color: "#ef4444" }}>{error}</span>}
              {success && <span style={{ fontSize: "13px", color: "#22c55e" }}>{success}</span>}
            </div>
          </form>
        </div>

        {/* User list */}
        <h3 style={{
          margin: "0 0 12px 0",
          fontSize: "15px",
          fontWeight: 600,
          color: "var(--text-primary)",
        }}>
          Existing Users
        </h3>
        {loading ? (
          <p style={{ color: "var(--text-secondary)", fontSize: "14px" }}>Loading...</p>
        ) : users.length === 0 ? (
          <div style={{
            background: "var(--bg-secondary)",
            border: "1px solid var(--border)",
            borderRadius: "12px",
            padding: "24px",
            textAlign: "center",
            color: "var(--text-secondary)",
            fontSize: "14px",
          }}>
            No users yet. Create one above to enable public access.
          </div>
        ) : (
          <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
            {users.map((user) => (
              <div
                key={user.id}
                style={{
                  display: "flex",
                  alignItems: "center",
                  justifyContent: "space-between",
                  background: "var(--bg-secondary)",
                  border: "1px solid var(--border)",
                  borderRadius: "10px",
                  padding: "12px 16px",
                }}
              >
                <div>
                  <div style={{ fontSize: "14px", fontWeight: 500, color: "var(--text-primary)" }}>
                    {user.username}
                  </div>
                  <div style={{ fontSize: "12px", color: "var(--text-secondary)" }}>
                    Created {new Date(user.created_at).toLocaleDateString()}
                  </div>
                </div>
                <button
                  onClick={() => handleDelete(user.id, user.username)}
                  disabled={deletingId === user.id}
                  style={{
                    background: "transparent",
                    border: "1px solid rgba(239,68,68,0.3)",
                    borderRadius: "8px",
                    padding: "6px 12px",
                    fontSize: "12px",
                    color: "#ef4444",
                    cursor: "pointer",
                    fontWeight: 500,
                  }}
                >
                  {deletingId === user.id ? "..." : "Delete"}
                </button>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

const fieldStyle: React.CSSProperties = {
  background: "var(--bg-primary)",
  border: "1px solid var(--border)",
  borderRadius: "8px",
  padding: "10px 12px",
  fontSize: "14px",
  color: "var(--text-primary)",
  outline: "none",
  boxSizing: "border-box",
};
