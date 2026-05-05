from __future__ import annotations

from typing import TypedDict

from langgraph.graph import END, StateGraph
from quipu import Quipu


class AgentState(TypedDict):
    user_input: str
    memory_context: str
    answer: str


memory = Quipu()
scope = {"projectId": "repo:langgraph-demo", "userId": "local-user"}


def load_memory(state: AgentState) -> AgentState:
    retrieved = memory.retrieve(
        query=state["user_input"],
        scope=scope,
        needs=["core", "current_facts", "preferences", "procedural", "recent_episodes"],
        budgetTokens=1000,
        options={"includeDebug": True},
    )
    return {**state, "memory_context": str(retrieved.get("prompt", ""))}


def answer(state: AgentState) -> AgentState:
    text = "I will use this memory context before acting:\n" + state["memory_context"]
    return {**state, "answer": text}


def save_turn(state: AgentState) -> AgentState:
    memory.remember(
        messages=[
            {"role": "user", "content": state["user_input"]},
            {"role": "assistant", "content": state["answer"]},
        ],
        scope=scope,
        extract=True,
    )
    return state


graph = StateGraph(AgentState)
graph.add_node("load_memory", load_memory)
graph.add_node("answer", answer)
graph.add_node("save_turn", save_turn)
graph.set_entry_point("load_memory")
graph.add_edge("load_memory", "answer")
graph.add_edge("answer", "save_turn")
graph.add_edge("save_turn", END)
app = graph.compile()


if __name__ == "__main__":
    result = app.invoke({"user_input": "For this repo, use pnpm and run just test.", "memory_context": "", "answer": ""})
    print(result["answer"])
    memory.close()
