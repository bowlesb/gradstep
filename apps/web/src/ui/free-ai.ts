// Free AI refusals (migration 0150; docs/PRICING_HOW_IT_WORKS.md): after `insufficient_credits` the balance is read once
// more, and when it says free AI can't pay right now (or the chosen model isn't one free AI covers) the reader is told why
// in the apps' words instead of the generic "not enough credits".
import { useEffect, useState } from 'react';
import { freeAIRefusal, parseBalance, type CreditBalance } from '../lib/account-summary';
import { rpc } from '../lib/backend';

/** The free-AI explanation for this refusal, read from a fresh balance; null otherwise (the usual words stay). */
export function useFreeAIRefusal(code: string | null | undefined, read: (() => Promise<CreditBalance | null | undefined>) | null,
  model?: string | null): string | null {
  const [balance, setBalance] = useState<CreditBalance | null>(null);
  useEffect(() => {
    setBalance(null);
    if (code !== 'insufficient_credits' || !read) return;
    let live = true;
    read().then(next => { if (live && next) setBalance(next); }, () => undefined);
    return () => { live = false; };
  }, [code, read]);
  return code === 'insufficient_credits' ? freeAIRefusal(balance, model) : null;
}

/** The chat session's balance, refreshed (ChatSession.refreshBalance keeps the last good read on failure). */
export const sessionBalance = (chat: { refreshBalance(): Promise<void>; balance: CreditBalance | null } | null | undefined) =>
  chat ? async () => { await chat.refreshBalance(); return chat.balance; } : null;

/** An account's balance, read directly (recommendations have no chat session). */
export const accountBalance = (account: string | null | undefined) =>
  account ? async () => parseBalance(await rpc<unknown>('v1_credit_balance', {}, { account })) : null;
