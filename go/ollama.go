package main

// Minimal Ollama /api/chat client — just the one non-streaming call the
// pipeline needs, against the local daemon on :11434.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
)

// summarizePrompt is byte-for-byte the prompt from meeting_pipeline.py.
const summarizePrompt = "Summarize this client meeting. Output sections: Context, " +
	"Decisions, Action items (owner + due date), Open questions.\n\n"

type chatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type chatRequest struct {
	Model    string         `json:"model"`
	Messages []chatMessage  `json:"messages"`
	Stream   bool           `json:"stream"`
	Options  map[string]any `json:"options"`
}

type chatResponse struct {
	Message chatMessage `json:"message"`
}

// ollamaClient has no timeout: a 7B model summarizing a multi-hour transcript
// can legitimately take many minutes, same as the Python client's default.
var ollamaClient = &http.Client{}

func summarize(cfg *config, transcript string) (string, error) {
	body, err := json.Marshal(chatRequest{
		Model:    cfg.llmModel,
		Messages: []chatMessage{{Role: "user", Content: summarizePrompt + transcript}},
		Stream:   false,
		Options:  map[string]any{"num_ctx": 16384},
	})
	if err != nil {
		return "", err
	}

	resp, err := ollamaClient.Post(cfg.ollamaURL, "application/json", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("ollama returned %s: %s", resp.Status, bytes.TrimSpace(respBody))
	}

	var parsed chatResponse
	if err := json.Unmarshal(respBody, &parsed); err != nil {
		return "", fmt.Errorf("decoding ollama response: %w", err)
	}
	return parsed.Message.Content, nil
}
