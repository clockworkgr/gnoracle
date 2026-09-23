package gnochain

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
)

// Ballot choices (gno.land/p/clockwork/gnoracle/tally/v0).
const (
	ChoiceUphold        = "UPHOLD"
	ChoiceOverturn      = "OVERTURN"
	ChoiceOverturnMinor = "OVERTURN_MINOR"
	ChoiceVoid          = "VOID"
	ChoiceAbstain       = "ABSTAIN"
)

// ValidChoice reports whether s is a ballot choice.
func ValidChoice(s string) bool {
	switch s {
	case ChoiceUphold, ChoiceOverturn, ChoiceOverturnMinor, ChoiceVoid, ChoiceAbstain:
		return true
	}
	return false
}

// Commitment mirrors tally.Commitment: the hex sha256 of
// "gnoracle|dispute|<id>|<round>|<choice>|<salt>|<voter>".
func Commitment(disputeID uint64, round int, choice, salt, voter string) string {
	msg := "gnoracle|dispute|" + strconv.FormatUint(disputeID, 10) + "|" + strconv.Itoa(round) + "|" + choice + "|" + salt + "|" + voter
	sum := sha256.Sum256([]byte(msg))
	return hex.EncodeToString(sum[:])
}

// NewSalt returns 16 random bytes as hex.
func NewSalt() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", err
	}
	return hex.EncodeToString(b[:]), nil
}
