import { Skeleton } from "@/components/ui/skeleton";

export function LoadingSkeleton({ cols = 5 }: { cols?: number }) {
  return (
    <div className="flex flex-col gap-1 p-2">
      {Array.from({ length: 20 }).map((_, i) => (
        <div key={i} className="flex gap-2">
          {Array.from({ length: cols }).map((_, j) => (
            <Skeleton key={j} className="h-5 flex-1" />
          ))}
        </div>
      ))}
    </div>
  );
}
