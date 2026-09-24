package impl

import (
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/clockwork/gnoracle/agg/v0"
	"gno.land/p/clockwork/gnoracle/jsonw/v0"
	"gno.land/r/clockwork/gnoracle/core"
)

// renderJSON serves the machine views under `:json/...` that the provider
// agent, the bot and the CLI read through vm/qrender. Chain state is public,
// so every value appears as soon as it exists; a subscription buys a realm
// the right to use a value in its own logic, not secrecy (plan §6.1). Every
// object carries "now" (block time) so a reader can compute rounds without a
// second query.
//
// Paths:
//
//	json/now
//	json/feeds[/<offset>[/<count>]]
//	json/feed/<id>
//	json/feed/<id>/round/<round|current>
//	json/feed/<id>/rounds[/<count>]
//	json/feed/<id>/provider/<addr>
//	json/feed/<id>/providers
//	json/feed/<id>/subscribers
//	json/feed/<id>/subscription/<realm path>
//	json/dispute/<id>
//	json/disputes[/<from>[/<count>]]
//	json/credit/<addr>
//	json/params
//	json/health
func renderJSON(st *core.StateRef, parts []string) string {
	if len(parts) == 0 {
		return jsonw.Error("path: json/now | feeds | feed/<id> | feed/<id>/round/<r> | feed/<id>/rounds | feed/<id>/provider/<addr> | feed/<id>/providers | feed/<id>/subscribers | feed/<id>/subscription/<realm> | dispute/<id> | disputes | credit/<addr> | params | health")
	}
	switch parts[0] {
	case "now":
		return jsonNow().String()
	case "feeds":
		offset, count := pageArgs(parts[1:], 0, 25, 100)
		a := jsonw.NewArray()
		core.IterateFeeds(int(offset), int(count), func(f *core.Feed) bool {
			a.Raw(jsonFeedSummary(f).String())
			return false
		})
		return jsonNow().Uint("total", core.FeedCount()).Raw("feeds", a.String()).String()
	case "feed":
		if len(parts) < 2 {
			return jsonw.Error("feed id missing")
		}
		id, err := strconv.ParseUint(parts[1], 10, 64)
		if err != nil {
			return jsonw.Error("bad feed id")
		}
		f := core.GetFeed(id)
		if f == nil {
			return jsonw.Error("unknown feed")
		}
		if len(parts) == 2 {
			return jsonFeed(st, f).String()
		}
		switch parts[2] {
		case "round":
			if len(parts) < 4 {
				return jsonw.Error("round id missing")
			}
			var rid uint64
			if parts[3] == "current" {
				cur, ok := schedule(f).Current(now())
				if !ok {
					return jsonNow().Uint("feed", id).Bool("started", false).String()
				}
				rid = cur
			} else if rid, err = strconv.ParseUint(parts[3], 10, 64); err != nil {
				return jsonw.Error("bad round id")
			}
			return jsonRound(st, f, rid).String()
		case "rounds":
			count := int64(20)
			if len(parts) >= 4 {
				if n, err := strconv.ParseInt(parts[3], 10, 64); err == nil && n > 0 && n <= 100 {
					count = n
				}
			}
			a := jsonw.NewArray()
			core.ReverseIterateRounds(id, int(count), func(rd *core.Round) bool {
				a.Raw(jsonRoundRecord(st, f, rd).String())
				return false
			})
			return jsonNow().Uint("feed", id).Raw("rounds", a.String()).String()
		case "provider":
			if len(parts) < 4 {
				return jsonw.Error("provider address missing")
			}
			p := core.GetProvider(id, address(parts[3]))
			if p == nil {
				return jsonw.Error("unknown provider")
			}
			return jsonProvider(p).String()
		case "providers":
			a := jsonw.NewArray()
			core.IterateProviders(id, func(p *core.Provider) bool {
				a.Raw(jsonProvider(p).String())
				return false
			})
			return jsonNow().Uint("feed", id).Raw("providers", a.String()).String()
		case "subscribers":
			a := jsonw.NewArray()
			t := now()
			core.IterateSubscriptions(id, func(s *core.Subscription) bool {
				a.Raw(jsonSubscription(s, t).String())
				return false
			})
			return jsonNow().Uint("feed", id).Int("subscriberPrice", f.Spec.SubscriberPrice).Bool("sponsored", f.Spec.Sponsored).Raw("subscribers", a.String()).String()
		case "subscription":
			if len(parts) < 4 {
				return jsonw.Error("realm path missing")
			}
			realmPath := strings.Join(parts[3:], "/")
			s := core.GetSubscription(id, realmPath)
			if s == nil {
				return jsonNow().Uint("feed", id).Str("realm", realmPath).Bool("exists", false).Bool("active", false).String()
			}
			return jsonSubscription(s, now()).String()
		}
		return jsonw.Error("unknown feed sub-path")
	case "dispute":
		if len(parts) < 2 {
			return jsonw.Error("dispute id missing")
		}
		id, err := strconv.ParseUint(parts[1], 10, 64)
		if err != nil {
			return jsonw.Error("bad dispute id")
		}
		d := core.GetDispute(id)
		if d == nil {
			return jsonw.Error("unknown dispute")
		}
		return jsonDispute(d).String()
	case "disputes":
		from, count := pageArgs(parts[1:], 1, 25, 100)
		if from < 1 {
			from = 1
		}
		a := jsonw.NewArray()
		total := core.DisputeCount()
		for id := uint64(from); id <= total && int64(a.Len()) < count; id++ {
			if d := core.GetDispute(id); d != nil {
				a.Raw(jsonDispute(d).String())
			}
		}
		return jsonNow().Uint("total", total).Raw("disputes", a.String()).String()
	case "credit":
		if len(parts) < 2 {
			return jsonw.Error("address missing")
		}
		c := core.GetCredit(address(parts[1]))
		o := jsonNow().Str("addr", parts[1])
		if c == nil {
			return o.Bool("exists", false).String()
		}
		return o.Bool("exists", true).Int("balance", c.Balance).Int("spent", c.Spent).String()
	case "params":
		return core.ParamsJSON()
	case "health":
		return jsonNow().Str("health", core.Health()).Int("balance", core.Balance()).Int("held", core.HeldTotal()).String()
	}
	return jsonw.Error("unknown json path")
}

// pageArgs parses [offset[/count]] with defaults and a ceiling on count.
func pageArgs(parts []string, defOffset, defCount, maxCount int64) (offset, count int64) {
	offset, count = defOffset, defCount
	if len(parts) >= 1 {
		if n, err := strconv.ParseInt(parts[0], 10, 64); err == nil && n >= 0 {
			offset = n
		}
	}
	if len(parts) >= 2 {
		if n, err := strconv.ParseInt(parts[1], 10, 64); err == nil && n > 0 {
			count = n
		}
	}
	if count > maxCount {
		count = maxCount
	}
	return
}

func jsonNow() *jsonw.Object {
	return jsonw.New().Int("now", now()).Int("height", runtime.ChainHeight()).Str("live", core.LivePath())
}

func jsonSubscription(s *core.Subscription, t int64) *jsonw.Object {
	return jsonNow().Uint("feed", s.Feed).Str("realm", s.Realm).Bool("exists", true).Int("since", s.Since).Int("paidUntil", s.PaidUntil).
		Int("paid", s.Paid).Int("periods", s.Periods).Bool("active", s.PaidUntil > t)
}

func jsonSpec(f *core.Feed) *jsonw.Object {
	s := f.Spec
	return jsonw.New().Str("name", s.Name).Str("description", s.Description).Str("kind", s.Kind).Str("valueType", s.ValueType).
		Int("decimals", int64(s.Decimals)).Strs("options", s.Options).Int("interval", s.Interval).Int("submitWindow", s.SubmitWindow).
		Int("resolveAt", s.ResolveAt).Int("bounty", s.Bounty).Str("sources", s.Sources).Int("minProviders", int64(s.MinProviders)).
		Int("maxProviders", int64(s.MaxProviders)).Int("providerMinStake", s.ProviderMinStake).Int("toleranceBps", s.ToleranceBps).
		Int("quarantineBps", s.QuarantineBps).Int("disputeWindow", s.DisputeWindow).Int("subscriberPrice", s.SubscriberPrice).
		Int("subscriptionPrice", s.SubscriptionPrice).Bool("sponsored", s.Sponsored).Int("valueAtStake", s.ValueAtStake).
		Strs("tags", s.Tags).Str("hash", s.Hash)
}

func jsonFeedSummary(f *core.Feed) *jsonw.Object {
	return jsonw.New().Uint("id", f.ID).Str("name", f.Spec.Name).Str("kind", f.Spec.Kind).Str("valueType", f.Spec.ValueType).
		Str("status", f.Status).Int("startAt", f.StartAt).Int("interval", f.Spec.Interval).Int("submitWindow", f.Spec.SubmitWindow).
		Int("decimals", int64(f.Spec.Decimals)).Int("activeCount", f.ActiveCount).Int("maxProviders", int64(f.Spec.MaxProviders)).
		Bool("haveLast", f.HaveLast).Uint("lastFinalized", f.LastFinalized).Int("openDisputes", f.OpenDisputes)
}

func jsonFeed(st *core.StateRef, f *core.Feed) *jsonw.Object {
	slots := jsonw.NewArray()
	for i := 0; i < agg.MaxSlots; i++ {
		slots.Str(string(f.SlotAt(i)))
	}
	o := jsonNow().Uint("id", f.ID).Str("proposer", string(f.Proposer)).Bool("fromRealm", f.FromRealm).Str("status", f.Status).
		Int("createdAt", f.CreatedAt).Int("startAt", f.StartAt).Int("deposit", f.Deposit).
		Int("pool", f.Pool).Int("drip", f.Drip).Int("feeAccrued", f.FeeAccrued).Int("penaltyCarry", f.PenaltyCarry).Int("paidUntil", f.PaidUntil).
		Int("activeCount", f.ActiveCount).Raw("slots", slots.String()).
		Bool("haveLast", f.HaveLast).Uint("lastFinalized", f.LastFinalized).Uint("oldestRound", f.OldestRound).Int("emptyStreak", f.EmptyStreak).
		Bool("haveValue", f.HaveValue).Uint("lastRound", f.LastRound).Int("lastRoundAt", f.LastRoundAt).Int("lastFinalAt", f.LastFinalAt).Str("lastTier", f.LastTier)
	if f.HaveValue {
		last, _ := st.FeedValues(f.ID)
		o.Int("value", last).Str("servedTier", servedTier(f, now()))
	}
	if cur, ok := schedule(f).Current(now()); ok {
		o.Uint("currentRound", cur).Int("currentOpenAt", schedule(f).OpenAt(cur)).Int("currentCloseAt", schedule(f).CloseAt(cur))
	}
	return o.Bool("reopened", f.Reopened).Int("deprecatedAt", f.DeprecatedAt).Int("openDisputes", f.OpenDisputes).
		Int("lastDisputeAt", f.LastDisputeAt).Int("disputesInRow", f.DisputesInRow).Int("subsidyPerRound", f.SubsidyPerRnd).
		Int("subsidyRemain", f.SubsidyRemain).Int("totalPaidOut", f.TotalPaidOut).Int("roundsFinal", f.RoundsFinal).
		Int("declaredValue", f.DeclaredValue).Raw("spec", jsonSpec(f).String())
}

// jsonRound describes round rid whether or not a record exists yet.
func jsonRound(st *core.StateRef, f *core.Feed, rid uint64) *jsonw.Object {
	sched := schedule(f)
	if sched.IsOneOff() && rid != 0 {
		return jsonNow().Uint("feed", f.ID).Uint("id", rid).Str("status", "none").Bool("exists", false)
	}
	if !sched.IsOneOff() {
		cur, ok := sched.Current(now())
		if !ok && rid > 0 || ok && rid > cur+1 {
			return jsonNow().Uint("feed", f.ID).Uint("id", rid).Str("status", "none").Bool("exists", false).Bool("scheduled", false)
		}
	}
	rd := core.GetRound(f.ID, rid)
	if rd == nil {
		t := now()
		return jsonNow().Uint("feed", f.ID).Uint("id", rid).Str("status", "none").Bool("exists", false).
			Int("opensAt", sched.OpenAt(rid)).Int("closesAt", sched.CloseAt(rid)).Bool("open", sched.IsOpen(rid, t)).Bool("closed", sched.IsClosed(rid, t))
	}
	return jsonRoundRecord(st, f, rd)
}

func jsonRoundRecord(st *core.StateRef, f *core.Feed, rd *core.Round) *jsonw.Object {
	sched := schedule(f)
	t := now()
	o := jsonNow().Uint("feed", rd.Feed).Uint("id", rd.ID).Str("status", rd.Status).Bool("exists", true).
		Int("opensAt", sched.OpenAt(rd.ID)).Int("closesAt", sched.CloseAt(rd.ID)).Bool("open", sched.IsOpen(rd.ID, t)).Bool("closed", sched.IsClosed(rd.ID, t)).
		Int("openedAt", rd.OpenedAt).Int("finalisedAt", rd.FinalisedAt).Str("tier", rd.Tier).Int("pool", rd.Pool).
		Uint("disputeID", rd.DisputeID).Bool("overturned", rd.Overturned).Int("submittedMask", int64(rd.SubmittedMask)).Int("eligibleMask", int64(rd.EligibleMask))
	submitted := jsonw.NewArray()
	for i := 0; i < agg.MaxSlots; i++ {
		if rd.SubmittedMask&(1<<uint(i)) != 0 {
			submitted.Raw(jsonw.New().Int("slot", int64(i)).Str("addr", string(core.SlotHolderAt(f.ID, int64(i), rd.ID))).String())
		}
	}
	o.Raw("submitted", submitted.String())
	if rd.Status != core.RoundOpen {
		vals := jsonw.NewArray()
		for i := 0; i < agg.MaxSlots; i++ {
			if rd.SubmittedMask&(1<<uint(i)) != 0 {
				vals.Raw(jsonw.New().Int("slot", int64(i)).Str("addr", string(core.SlotHolderAt(f.ID, int64(i), rd.ID))).Int("value", st.RoundValueAt(f.ID, rd.ID, i)).
					Bool("eligible", rd.EligibleMask&(1<<uint(i)) != 0).String())
			}
		}
		o.Int("value", st.RoundValue(f.ID, rd.ID)).Raw("values", vals.String())
	}
	return o
}

func jsonProvider(p *core.Provider) *jsonw.Object {
	return jsonNow().Uint("feed", p.Feed).Str("addr", string(p.Addr)).Int("stake", p.Stake).Str("status", p.Status).Int("slot", p.Slot).
		Str("memo", p.Memo).Int("joinedAt", p.JoinedAt).Uint("obligedFrom", p.ObligedFrom).Int("consecutiveMisses", p.ConsecutiveMisses).
		Int("strikes", p.Strikes).Uint("strikeWindowStart", p.StrikeWindowStart).Int("missSlashedEpoch", p.MissSlashedEpoch).
		Int("minorsEpoch", p.MinorsEpoch).Int("epochStart", p.EpochStart).Int("jailings", p.Jailings).Int("jailingsSince", p.JailingsSince).
		Int("jailedAt", p.JailedAt).Uint("lastSubmitted", p.LastSubmitted).Bool("hasSubmitted", p.HasSubmitted).
		Int("unbondAmount", p.UnbondAmount).Int("unbondReadyAt", p.UnbondReadyAt).Int("rewards", p.Rewards).
		Int("totalEarned", p.TotalEarned).Int("totalSlashed", p.TotalSlashed)
}

func jsonDispute(d *core.DisputeRecord) *jsonw.Object {
	o := jsonNow().Uint("id", d.ID).Uint("feed", d.Feed).Uint("round", d.Round).Str("disputer", string(d.Disputer)).Int("bond", d.Bond).
		Int("proposedValue", d.ProposedValue).Str("tierAsked", d.TierAsked).Str("evidence", d.Evidence).Str("evidenceHash", d.EvidenceHash).
		Int("openedAt", d.OpenedAt).Str("status", d.Status).Int("ballotRound", d.BallotRound).Str("outcome", d.Outcome).
		Str("firstOutcome", d.FirstOutcome).Str("tierDecided", d.TierDecided).Int("decidedAt", d.DecidedAt).Int("resolvedAt", d.ResolvedAt).
		Str("appellant", string(d.Appellant)).Int("appealBond", d.AppealBond).Int("appealAt", d.AppealAt).Int("coherentWeight", d.CoherentW).
		Int("slashed", d.Slashed).Int("priorValue", d.PriorValue).Str("priorTier", d.PriorTier)
	if d.Status == core.DisputeDecided {
		o.Int("appealWindowEnds", d.DecidedAt+param("appealWindow"))
	}
	return o
}

// ---- dispute pages

func renderDisputes() string {
	total := core.DisputeCount()
	out := "# Disputes\n\n" + u(total) + " so far. Ballots run on the [DAO](" + webPath(core.DAOPath) + "); verdicts are mirrored to [Kourt](" + webPath(core.ParamStr("kourtRealm")) + ").\n\n| id | feed | round | status | outcome | opened |\n|---|---|---|---|---|---|\n"
	shown := 0
	for id := total; id >= 1 && shown < 50; id-- {
		d := core.GetDispute(id)
		if d == nil {
			continue
		}
		out += "| [" + u(id) + "](:dispute/" + u(id) + ") | [" + u(d.Feed) + "](:feed/" + u(d.Feed) + ") | " + u(d.Round) + " | " + d.Status + " | " + d.Outcome + " | " + i(d.OpenedAt) + " |\n"
		shown++
	}
	return out
}

func renderDispute(id uint64) string {
	d := core.GetDispute(id)
	if d == nil {
		return "unknown dispute"
	}
	f := core.GetFeed(d.Feed)
	out := "# Dispute " + u(id) + "\n\n"
	out += "| | |\n|---|---|\n"
	out += "| feed | [" + u(d.Feed) + "](:feed/" + u(d.Feed) + ") |\n| round | " + u(d.Round) + " |\n| status | " + d.Status + " |\n"
	out += "| disputer | " + string(d.Disputer) + " |\n| bond | " + i(d.Bond) + " ugnot |\n| asks for | " + d.TierAsked + " |\n"
	if f != nil {
		out += "| proposed value | " + formatValue(f, d.ProposedValue) + " |\n"
	}
	out += "| opened | " + i(d.OpenedAt) + " |\n| ballot round | " + i(d.BallotRound) + " |\n"
	if d.Outcome != "" {
		out += "| outcome | " + d.Outcome + " / " + d.TierDecided + " |\n| decided | " + i(d.DecidedAt) + " |\n"
	}
	if d.Status == core.DisputeDecided {
		out += "| appeal window ends | " + i(d.DecidedAt+param("appealWindow")) + " |\n"
	}
	if d.Appellant != "" {
		out += "| appellant | " + string(d.Appellant) + " |\n| appeal bond | " + i(d.AppealBond) + " ugnot |\n"
	}
	if d.Status == core.DisputeResolved {
		out += "| resolved | " + i(d.ResolvedAt) + " |\n| slashed | " + i(d.Slashed) + " ugnot |\n"
	}
	out += "| evidence hash | `" + d.EvidenceHash + "` |\n\n"
	out += "Ballot: [DAO dispute " + u(id) + "](" + webPath(core.DAOPath) + ":ballot/dispute/" + u(id) + ") · Court of record: [Kourt mirror](" + webPath(core.ParamStr("kourtRealm")) + ":dispute/" + u(id) + ")\n\n"
	out += "## Evidence\n\n" + esc(d.Evidence) + "\n"
	return out
}

// webPath turns a package path into a gnoweb link.
func webPath(pkgPath string) string { return strings.TrimPrefix(pkgPath, "gno.land") }
