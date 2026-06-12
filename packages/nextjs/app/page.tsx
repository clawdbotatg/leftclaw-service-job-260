"use client";

import { useEffect, useState } from "react";
import { Address } from "@scaffold-ui/components";
import type { NextPage } from "next";
import { formatEther, parseEther } from "viem";
import { base } from "viem/chains";
import { useAccount, useChainId, useSwitchChain } from "wagmi";
import { RainbowKitCustomConnectButton } from "~~/components/scaffold-eth";
import { useScaffoldEventHistory, useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import { notification } from "~~/utils/scaffold-eth";

// ─── Types ────────────────────────────────────────────────────────────────────

type ContentType = 0 | 1 | 2 | 3;
type ContentStatus = 0 | 1 | 2 | 3;

type Content = {
  id: bigint;
  creator: `0x${string}`;
  title: string;
  description: string;
  contentType: ContentType;
  ipfsCID: string;
  submittedAt: bigint;
  status: ContentStatus;
  score: bigint;
  totalVoteWeight: bigint;
  disputeStake: bigint;
  disputer: `0x${string}`;
  disputeDeadline: bigint;
};

const CONTENT_TYPE_LABELS: Record<number, string> = {
  0: "Film",
  1: "Music",
  2: "Art",
  3: "Writing",
};

const STATUS_LABELS: Record<number, string> = {
  0: "Active",
  1: "Disputed",
  2: "Finalized",
  3: "Removed",
};

const STATUS_BADGE_CLASS: Record<number, string> = {
  0: "badge-success",
  1: "badge-warning",
  2: "badge-info",
  3: "badge-error",
};

// ─── ContentCard ──────────────────────────────────────────────────────────────

function ContentCard({
  contentId,
  rank,
  onDisputeSuccess,
}: {
  contentId: bigint;
  rank: number;
  onDisputeSuccess?: () => void;
}) {
  const { isConnected } = useAccount();
  const chainId = useChainId();
  const { switchChain } = useSwitchChain();

  const { data: content } = useScaffoldReadContract({
    contractName: "ContentRanking",
    functionName: "getContent",
    args: [contentId],
  });

  const { data: votingOpen } = useScaffoldReadContract({
    contractName: "ContentRanking",
    functionName: "isVotingOpen",
    args: [contentId],
  });

  const { data: disputeFee } = useScaffoldReadContract({
    contractName: "ContentRanking",
    functionName: "disputeStakeRequired",
  });

  const { writeContractAsync: writeDispute, isPending: disputePending } = useScaffoldWriteContract({
    contractName: "ContentRanking",
  });

  if (!content) {
    return (
      <div className="card bg-base-200 shadow animate-pulse">
        <div className="card-body h-32" />
      </div>
    );
  }

  const c = content as unknown as Content;
  const scoreNum = c.score;
  const scorePositive = scoreNum >= 0n;
  const scoreDisplay = scorePositive ? `+${scoreNum.toString()}` : scoreNum.toString();

  const canDispute = c.status === 0 && !votingOpen;

  const handleDispute = async () => {
    if (!isConnected) return;
    if (chainId !== base.id) {
      switchChain({ chainId: base.id });
      return;
    }
    try {
      await writeDispute({
        functionName: "dispute",
        args: [contentId],
        value: disputeFee ?? parseEther("0.001"),
      });
      notification.success("Dispute filed!");
      onDisputeSuccess?.();
    } catch {
      notification.error("Dispute failed");
    }
  };

  return (
    <div className="card bg-base-100 shadow-md border border-base-300">
      <div className="card-body gap-2 p-4">
        <div className="flex items-start justify-between gap-2">
          <div className="flex items-center gap-2 min-w-0">
            <span className="text-2xl font-bold text-base-content/40 shrink-0">#{rank}</span>
            <div className="min-w-0">
              <h3 className="font-bold text-base truncate">{c.title}</h3>
              <p className="text-sm text-base-content/70 line-clamp-2">{c.description}</p>
            </div>
          </div>
          <div className="flex flex-col items-end gap-1 shrink-0">
            <span className={`text-lg font-bold ${scorePositive ? "text-success" : "text-error"}`}>{scoreDisplay}</span>
            <span className="text-xs text-base-content/50">score</span>
          </div>
        </div>

        <div className="flex flex-wrap items-center gap-2 mt-1">
          <span className="badge badge-outline badge-sm">{CONTENT_TYPE_LABELS[c.contentType] ?? "Unknown"}</span>
          <span className={`badge badge-sm ${STATUS_BADGE_CLASS[c.status] ?? "badge-ghost"}`}>
            {STATUS_LABELS[c.status] ?? "Unknown"}
          </span>
          {votingOpen ? (
            <span className="badge badge-primary badge-sm">Voting Open</span>
          ) : (
            <span className="badge badge-ghost badge-sm">Voting Closed</span>
          )}
        </div>

        <div className="flex items-center justify-between mt-1 text-xs text-base-content/60">
          <div className="flex items-center gap-1">
            <span>By:</span>
            <Address address={c.creator} size="xs" />
          </div>
          {c.ipfsCID && (
            <a
              href={`https://ipfs.io/ipfs/${c.ipfsCID}`}
              target="_blank"
              rel="noopener noreferrer"
              className="link link-primary truncate max-w-[120px]"
              title={c.ipfsCID}
            >
              View on IPFS
            </a>
          )}
        </div>

        {canDispute && (
          <div className="mt-2">
            {!isConnected ? (
              <RainbowKitCustomConnectButton />
            ) : chainId !== base.id ? (
              <button className="btn btn-warning btn-sm w-full" onClick={() => switchChain({ chainId: base.id })}>
                Switch to Base to Dispute
              </button>
            ) : (
              <button className="btn btn-warning btn-sm w-full" onClick={handleDispute} disabled={disputePending}>
                {disputePending ? (
                  <>
                    <span className="loading loading-spinner loading-sm" /> Filing Dispute...
                  </>
                ) : (
                  `File Dispute (${disputeFee ? formatEther(disputeFee) : "0.001"} ETH)`
                )}
              </button>
            )}
          </div>
        )}
      </div>
    </div>
  );
}

// ─── RankingsTab ──────────────────────────────────────────────────────────────

function RankingsTab() {
  const { data: rankedIds, isLoading } = useScaffoldReadContract({
    contractName: "ContentRanking",
    functionName: "getRankedContent",
    args: [20n],
  });

  if (isLoading) {
    return (
      <div className="flex justify-center py-16">
        <span className="loading loading-spinner loading-lg" />
      </div>
    );
  }

  const ids = rankedIds as bigint[] | undefined;

  if (!ids || ids.length === 0) {
    return (
      <div className="text-center py-16 text-base-content/50">
        <p className="text-xl">No content yet</p>
        <p className="text-sm mt-2">Be the first to submit content!</p>
      </div>
    );
  }

  return (
    <div className="grid grid-cols-1 md:grid-cols-2 gap-4">
      {ids.map((id, i) => (
        <ContentCard key={id.toString()} contentId={id} rank={i + 1} />
      ))}
    </div>
  );
}

// ─── SubmitTab ────────────────────────────────────────────────────────────────

function SubmitTab({ onSuccess }: { onSuccess: () => void }) {
  const { isConnected } = useAccount();
  const chainId = useChainId();
  const { switchChain } = useSwitchChain();

  const [title, setTitle] = useState("");
  const [description, setDescription] = useState("");
  const [contentType, setContentType] = useState<number>(0);
  const [ipfsCID, setIpfsCID] = useState("");

  const { data: submissionFee } = useScaffoldReadContract({
    contractName: "ContentRanking",
    functionName: "submissionFee",
  });

  const { writeContractAsync, isPending } = useScaffoldWriteContract({
    contractName: "ContentRanking",
  });

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!title.trim() || !ipfsCID.trim()) {
      notification.error("Title and IPFS CID are required");
      return;
    }
    try {
      await writeContractAsync({
        functionName: "submitContent",
        args: [title, description, contentType as ContentType, ipfsCID],
        value: submissionFee ?? 10000000000000n,
      });
      notification.success("Content submitted!");
      setTitle("");
      setDescription("");
      setContentType(0);
      setIpfsCID("");
      onSuccess();
    } catch {
      notification.error("Submission failed");
    }
  };

  if (!isConnected) {
    return (
      <div className="flex flex-col items-center gap-4 py-16">
        <p className="text-base-content/70">Connect your wallet to submit content</p>
        <RainbowKitCustomConnectButton />
      </div>
    );
  }

  if (chainId !== base.id) {
    return (
      <div className="flex flex-col items-center gap-4 py-16">
        <p className="text-base-content/70">Switch to Base network to submit content</p>
        <button className="btn btn-primary" onClick={() => switchChain({ chainId: base.id })}>
          Switch to Base
        </button>
      </div>
    );
  }

  const feeDisplay = submissionFee ? formatEther(submissionFee) : "0.00001";

  return (
    <div className="max-w-lg mx-auto">
      <div className="card bg-base-100 shadow-md border border-base-300">
        <div className="card-body gap-4">
          <h2 className="card-title">Submit Content</h2>
          <p className="text-sm text-base-content/60">
            Submission fee: <span className="font-semibold text-primary">{feeDisplay} ETH</span>
          </p>
          <form onSubmit={handleSubmit} className="flex flex-col gap-4">
            <div className="form-control">
              <label className="label">
                <span className="label-text font-medium">Title *</span>
              </label>
              <input
                type="text"
                className="input input-bordered w-full"
                placeholder="Enter content title"
                value={title}
                onChange={e => setTitle(e.target.value)}
                required
              />
            </div>

            <div className="form-control">
              <label className="label">
                <span className="label-text font-medium">Description</span>
              </label>
              <textarea
                className="textarea textarea-bordered w-full"
                placeholder="Describe your content"
                rows={3}
                value={description}
                onChange={e => setDescription(e.target.value)}
              />
            </div>

            <div className="form-control">
              <label className="label">
                <span className="label-text font-medium">Content Type</span>
              </label>
              <select
                className="select select-bordered w-full"
                value={contentType}
                onChange={e => setContentType(Number(e.target.value))}
              >
                <option value={0}>Film</option>
                <option value={1}>Music</option>
                <option value={2}>Art</option>
                <option value={3}>Writing</option>
              </select>
            </div>

            <div className="form-control">
              <label className="label">
                <span className="label-text font-medium">IPFS CID *</span>
                <span className="label-text-alt text-base-content/50">Upload to IPFS first</span>
              </label>
              <input
                type="text"
                className="input input-bordered w-full"
                placeholder="QmYourIPFSCIDHere..."
                value={ipfsCID}
                onChange={e => setIpfsCID(e.target.value)}
                required
              />
              <label className="label">
                <span className="label-text-alt text-base-content/50">
                  Upload your content to IPFS first and paste the CID here
                </span>
              </label>
            </div>

            <button type="submit" className="btn btn-primary w-full" disabled={isPending}>
              {isPending ? (
                <>
                  <span className="loading loading-spinner loading-sm" /> Submitting...
                </>
              ) : (
                `Submit Content (${feeDisplay} ETH)`
              )}
            </button>
          </form>
        </div>
      </div>
    </div>
  );
}

// ─── VoteHistoryItem ──────────────────────────────────────────────────────────

function VoteHistoryItem({
  contentId,
  isUpvote,
  burnAmount,
}: {
  contentId: bigint;
  isUpvote: boolean;
  burnAmount: bigint;
}) {
  const { data: content } = useScaffoldReadContract({
    contractName: "ContentRanking",
    functionName: "getContent",
    args: [contentId],
  });

  const c = content as unknown as Content | undefined;

  return (
    <div className="flex items-center justify-between p-3 bg-base-200 rounded-lg">
      <div className="flex items-center gap-3 min-w-0">
        <span className={`text-2xl ${isUpvote ? "text-success" : "text-error"}`}>{isUpvote ? "▲" : "▼"}</span>
        <div className="min-w-0">
          <p className="font-medium truncate">{c?.title ?? `Content #${contentId.toString()}`}</p>
          <p className="text-xs text-base-content/60">
            Burned: <span className="font-semibold">{formatEther(burnAmount)} CLAWD</span>
          </p>
        </div>
      </div>
      <span className={`badge ${isUpvote ? "badge-success" : "badge-error"} shrink-0`}>
        {isUpvote ? "Upvote" : "Downvote"}
      </span>
    </div>
  );
}

// ─── MyVotesTab ───────────────────────────────────────────────────────────────

function MyVotesTab() {
  const { isConnected, address } = useAccount();

  const { data: events, isLoading } = useScaffoldEventHistory({
    contractName: "ContentRanking",
    eventName: "Voted",
    fromBlock: 0n,
    filters: { voter: address },
    enabled: isConnected && !!address,
  });

  if (!isConnected) {
    return (
      <div className="flex flex-col items-center gap-4 py-16">
        <p className="text-base-content/70">Connect your wallet to see your vote history</p>
        <RainbowKitCustomConnectButton />
      </div>
    );
  }

  if (isLoading) {
    return (
      <div className="flex justify-center py-16">
        <span className="loading loading-spinner loading-lg" />
      </div>
    );
  }

  const recentEvents = events?.slice(0, 10) ?? [];

  if (recentEvents.length === 0) {
    return (
      <div className="text-center py-16 text-base-content/50">
        <p className="text-xl">No votes yet</p>
        <p className="text-sm mt-2">Vote on content in the Rankings tab</p>
      </div>
    );
  }

  return (
    <div className="max-w-lg mx-auto flex flex-col gap-3">
      <h2 className="text-lg font-bold">Your Recent Votes</h2>
      {recentEvents.map((event, i) => {
        const args = event.args as { contentId: bigint; voter: `0x${string}`; isUpvote: boolean; burnAmount: bigint };
        return (
          <VoteHistoryItem
            key={`${event.transactionHash}-${i}`}
            contentId={args.contentId}
            isUpvote={args.isUpvote}
            burnAmount={args.burnAmount}
          />
        );
      })}
    </div>
  );
}

// ─── Page ─────────────────────────────────────────────────────────────────────

type Tab = "rankings" | "submit" | "votes";

const Home: NextPage = () => {
  const [activeTab, setActiveTab] = useState<Tab>("rankings");
  const [mounted, setMounted] = useState(false);

  useEffect(() => {
    setMounted(true);
  }, []);

  if (!mounted) {
    return (
      <div className="flex flex-col grow">
        <div className="bg-base-200 py-10 px-4 text-center">
          <h1 className="text-4xl font-extrabold mb-2">Larva Content Rankings</h1>
          <p className="text-base-content/70 text-lg">Debate content quality onchain. Every vote burns CLAWD.</p>
        </div>
        <div className="flex justify-center py-16">
          <span className="loading loading-spinner loading-lg" />
        </div>
      </div>
    );
  }

  return (
    <div className="flex flex-col grow">
      {/* Hero header */}
      <div className="bg-base-200 py-10 px-4 text-center">
        <h1 className="text-4xl font-extrabold mb-2">Larva Content Rankings</h1>
        <p className="text-base-content/70 text-lg">Debate content quality onchain. Every vote burns CLAWD.</p>
      </div>

      {/* Tab bar */}
      <div className="flex justify-center pt-6 px-4">
        <div className="tabs tabs-boxed gap-1">
          <button
            className={`tab ${activeTab === "rankings" ? "tab-active" : ""}`}
            onClick={() => setActiveTab("rankings")}
          >
            Rankings
          </button>
          <button
            className={`tab ${activeTab === "submit" ? "tab-active" : ""}`}
            onClick={() => setActiveTab("submit")}
          >
            Submit
          </button>
          <button className={`tab ${activeTab === "votes" ? "tab-active" : ""}`} onClick={() => setActiveTab("votes")}>
            My Votes
          </button>
        </div>
      </div>

      {/* Tab content */}
      <div className="grow px-4 py-6 max-w-4xl w-full mx-auto">
        {activeTab === "rankings" && <RankingsTab />}
        {activeTab === "submit" && <SubmitTab onSuccess={() => setActiveTab("rankings")} />}
        {activeTab === "votes" && <MyVotesTab />}
      </div>
    </div>
  );
};

export default Home;
