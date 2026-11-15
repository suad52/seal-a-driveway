local Bindings = {}
Bindings.Pages = {"Passes", "Cash", "Boosts"}
Bindings.Items = {
 {tab="Passes", card="2xCash", id="DoubleCash", kind="Pass"},
 {tab="Passes", card="VIP", id="VIP", kind="Pass"},
 {tab="Passes", card="Cyberseal", id="CyberRig", kind="Pass"},
 {tab="Passes", card="StarterRig", id="PermanentRig", kind="Pass"},
 {tab="Passes", card="Squeegee", id="TruckBlade", kind="Pass"},
 {tab="Passes", card="SprayBar", id="TruckPour", kind="Pass"},
 {tab="Passes", card="InstantRefill", id="InstantFill", kind="Pass"},
 {tab="Cash", card="25K", id="Wad", kind="Cash"},
 {tab="Cash", card="100K", id="Roll", kind="Cash"},
 {tab="Cash", card="500K", id="Case", kind="Cash"},
 {tab="Cash", card="2_5M", id="Pallet", kind="Cash"},
 {tab="Cash", card="10M", id="Vault", kind="Cash"},
 {tab="Boosts", card="InstantCoat", title="Instant Coat", id="Endless", kind="Boost"},
 {tab="Boosts", card="InstantCoat", title="Helper", id="Helper", kind="Helper"},
 {tab="Boosts", card="Bundle", id="BlueberryBundle", kind="Pass"},
}
function Bindings.list(page)
 return page:FindFirstChild("Panel") and page.Panel:FindFirstChild("Inner") and page.Panel.Inner:FindFirstChild("Content") and page.Panel.Inner.Content:FindFirstChild("Catalogue") and page.Panel.Inner.Content.Catalogue:FindFirstChild("List")
end
function Bindings.card(page, item)
 local list = Bindings.list(page)
 if not list then return nil end
 local found, best = nil, -1
 local matchesList = {}
 for _, child in ipairs(list:GetChildren()) do
  if child:IsA("GuiObject") then
   local matches = child:GetAttribute("ShopItemId") == item.id
   if child:GetAttribute("ShopItemId") == nil and child.Name == item.card then
    matches = item.title == nil
    if item.title then
     for _, text in ipairs(child:GetDescendants()) do
      if text:IsA("TextLabel") and text.Text == item.title then matches = true; break end
     end
    end
   end
   if matches then
    local score = child:GetAttribute("ShopItemId") == item.id and 2 or 1
    if item.title then
     local hasTitle, hasOtherTitle = false, false
     for _, text in ipairs(child:GetDescendants()) do
      if text:IsA("TextLabel") then
       if text.Text == item.title then hasTitle = true end
       for _, definition in ipairs(Bindings.Items) do
        if definition.title and definition.title ~= item.title and text.Text == definition.title then
         hasOtherTitle = true
        end
       end
      end
     end
     if hasTitle then score += 4 elseif hasOtherTitle then score = -1 end
    end
    if score >= 0 then
     table.insert(matchesList, child)
     if score > best then found, best = child, score end
    end
   end
  end
 end
 for _, duplicate in ipairs(matchesList) do
  if duplicate ~= found then
   duplicate.Visible = false
   duplicate.Active = false
   duplicate.Selectable = false
   duplicate:SetAttribute("ShopBindingDuplicate", true)
  end
 end
 return found
end
function Bindings.button(card)
 local holder = card and card:FindFirstChild("Button")
 local cap = holder and holder:FindFirstChild("Cap")
 return if cap and cap:IsA("GuiButton") then cap else nil
end
return Bindings
