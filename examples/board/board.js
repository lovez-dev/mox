"use strict";

const form = document.querySelector("#create-task");
const notice = document.querySelector("#notice");

async function mutate(url, method, value) {
  notice.textContent = "Saving...";
  try {
    const response = await fetch(url, {
      method,
      headers: value === undefined ? {} : { "Content-Type": "application/json" },
      body: value === undefined ? undefined : JSON.stringify(value),
    });
    if (!response.ok) {
      const error = await response.json();
      throw new Error(error.error || "Unable to save task");
    }
    window.location.reload();
  } catch (error) {
    notice.textContent = error instanceof Error ? error.message : "Unable to save task";
    return false;
  }
  return true;
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  const button = form.querySelector("button");
  button.disabled = true;
  await mutate("/api/tasks", "POST", { title: form.elements.title.value });
  button.disabled = false;
});

document.querySelectorAll(".tasks li[data-id]").forEach((row) => {
  const url = `/api/tasks/${row.dataset.id}`;
  const checkbox = row.querySelector('input[type="checkbox"]');
  checkbox.addEventListener("change", async () => {
    const done = checkbox.checked;
    checkbox.disabled = true;
    if (!(await mutate(url, "PATCH", { done }))) checkbox.checked = !done;
    checkbox.disabled = false;
  });
  const button = row.querySelector(".delete");
  button.addEventListener("click", async () => {
    button.disabled = true;
    await mutate(url, "DELETE");
    button.disabled = false;
  });
});
